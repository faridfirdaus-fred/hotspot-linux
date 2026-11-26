#!/usr/bin/env bash
# hotspot-linux — manage the patched iwlmvm install + hotspot lifecycle.
# Target kernel defaults to the running one; override with IWLWVM_LAR_KVER.
# Preferred entry points are the hotspot-on/off/status/setting wrappers
# (installed to /usr/local/bin by install.sh / install-cmds).
set -Eeuo pipefail

KVER=${IWLWVM_LAR_KVER:-$(uname -r)}
TARGET=/lib/modules/$KVER/updates/iwlmvm.ko
TARGET_TMP=$TARGET.tmp
REGDOM=/etc/modprobe.d/cfg80211-regdom.conf
SERVICE=create_ap.service
CONF=${HOTSPOT_CONF:-/etc/create_ap.conf}
DROPIN=/etc/systemd/system/$SERVICE.d/iwlmvm-lar.conf

die()       { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "run with sudo: sudo $0 $1"; }

svc_state()  { systemctl show "$SERVICE" -p ActiveState --value 2>/dev/null || echo unknown; }
svc_is_on()  { [[ $(svc_state) == active ]]; }
svc_is_off() { local s; s=$(svc_state); [[ $s == inactive || $s == failed ]]; }

trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

conf_get() { # $1=KEY -> last value, trimmed (unquoted if wrapped in double quotes)
    local k=$1 v
    v=$(awk -F= -v k="$k" \
        '$0 ~ "^[[:space:]]*" k "[[:space:]]*=" { v = substr($0, index($0, "=") + 1) }
         END { print v }' "$CONF" 2>/dev/null || true)
    v=$(trim "$v")
    if [[ $v == '"'*'"' && ${#v} -ge 2 ]]; then
        v=${v#\"}; v=${v%\"}
    fi
    printf '%s' "$v"
}

conf_set() { # $1=KEY $2=VALUE -> atomic in-place update or append (safe for special chars)
    local k=$1 v=$2 tmp
    tmp=$(mktemp "${CONF}.tmp.XXXXXX")
    awk -v k="$k" -v v="$v" '
        BEGIN { found = 0 }
        $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
            print k "=" v
            found = 1
            next
        }
        { print }
        END {
            if (!found) print k "=" v
        }
    ' "$CONF" > "$tmp"
    chmod --reference="$CONF" "$tmp" 2>/dev/null || chmod 0600 "$tmp"
    mv "$tmp" "$CONF"
}

configured_country() {
    local c=''
    if [[ -r $REGDOM ]]; then
        c=$(awk -F= '/^[[:space:]]*options[[:space:]]+cfg80211[[:space:]]+ieee80211_regdom=/{print $2; exit}' "$REGDOM" 2>/dev/null || true)
        c=$(trim "$c")
    fi
    printf '%s' "${c:-ID}"
}

detect_wifi_iface() {
    local iface
    iface=$(iw dev 2>/dev/null | awk '
        $1 == "Interface" { cur = $2 }
        $1 == "type" && $2 == "managed" { print cur; exit }
    ' || true)
    if [[ -n $iface ]]; then
        printf '%s' "$iface"
        return 0
    fi
    for d in /sys/class/net/*/wireless; do
        [[ -d $d ]] || continue
        iface=${d#/sys/class/net/}
        printf '%s' "${iface%/wireless}"
        return 0
    done
    printf '%s' 'wlan0'
}

uplink_iface() {
    local w i
    w=$(conf_get WIFI_IFACE)
    i=$(conf_get INTERNET_IFACE)
    if [[ -n $w && -d /sys/class/net/$w ]]; then
        printf '%s' "$w"
    elif [[ -n $i && -d /sys/class/net/$i/wireless ]]; then
        printf '%s' "$i"
    else
        detect_wifi_iface
    fi
}

ap_iface() {
    local iface
    iface=$(iw dev 2>/dev/null | awk '
        $1 == "Interface" { cur = $2 }
        $1 == "type" && $2 == "AP" { print cur; exit }
    ' || true)
    printf '%s' "${iface:-ap0}"
}

# Compute a hostapd-safe HT_CAPAB value for the given band + channel so that
# aligning to e.g. channel 40, 48, 153, 161, 165, or 2.4 GHz ch 11 does not
# cause hostapd to reject [HT40+].
safe_ht_capab() { # $1=band(2.4|5) $2=channel
    local band=$1 ch=$2
    if [[ $band == 5 ]]; then
        case $ch in
            36|44|52|60|100|108|116|124|132|140|149|157) printf '%s' '[HT40+]' ;;
            40|48|56|64|104|112|120|128|136|144|153|161) printf '%s' '[HT40-]' ;;
            *) printf '%s' '' ;; # e.g. ch 165 is 20 MHz only
        esac
    else
        if (( ch >= 1 && ch <= 7 )); then
            printf '%s' '[HT40+]'
        elif (( ch >= 8 && ch <= 13 )); then
            printf '%s' '[HT40-]'
        else
            printf '%s' ''
        fi
    fi
}

align_channel() {
    # Single radio: the AP must ride the station uplink's channel.
    # Syncs CHANNEL, FREQ_BAND, and HT_CAPAB in $CONF to the live uplink channel.
    local iface ch freq cfg_ch cfg_band cfg_ht band ht
    [[ -f $CONF ]] || { printf 'WARN: missing %s; keeping requested channel\n' "$CONF" >&2; return 0; }
    iface=$(uplink_iface)
    ch=$(iw dev "$iface" info 2>/dev/null | awk '$1=="channel"{print $2; exit}' || true)
    freq=$(iw dev "$iface" info 2>/dev/null | awk '$1=="channel"{gsub(/[()]/,"",$3); print $3; exit}' || true)
    [[ -n $ch ]] || return 0 # uplink down/disconnected: keep configured channel

    if [[ -n $freq ]] && (( freq < 3000 )); then
        band=2.4
    else
        band=5
    fi

    if [[ $band == 5 ]] && (( ch >= 52 && ch <= 144 )); then
        printf 'WARN: uplink %s is on DFS channel %s (%s MHz); Intel AX201 AP mode may fail on DFS channels\n' \
            "$iface" "$ch" "${freq:-?}" >&2
    fi

    ht=$(safe_ht_capab "$band" "$ch")
    cfg_ch=$(conf_get CHANNEL)
    cfg_band=$(conf_get FREQ_BAND)
    cfg_ht=$(conf_get HT_CAPAB)

    if [[ $cfg_ch != "$ch" || $cfg_band != "$band" || $cfg_ht != "$ht" ]]; then
        # Keep a true one-time backup of the user's original config
        [[ -e $CONF.bak-align ]] || cp -a -- "$CONF" "$CONF.bak-align"
        conf_set CHANNEL "$ch"
        conf_set FREQ_BAND "$band"
        conf_set HT_CAPAB "$ht"
        printf 'aligning AP channel %s -> %s (band %s GHz, HT %s; uplink %s%s)\n' \
            "${cfg_ch:-unset}" "$ch" "$band" "${ht:-HT20}" "$iface" "${freq:+ / $freq MHz}"
    fi
    return 0
}

firewalld_active() {
    command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1
}

firewalld_allow_ap() {
    local iface=${1:-ap0}
    firewalld_active || return 0
    if ! firewall-cmd --zone=trusted --query-interface="$iface" >/dev/null 2>&1; then
        firewall-cmd --zone=trusted --add-interface="$iface" >/dev/null 2>&1 || true
    fi
}

firewalld_revoke_ap() {
    local iface=${1:-ap0}
    firewalld_active || return 0
    if firewall-cmd --zone=trusted --query-interface="$iface" >/dev/null 2>&1; then
        firewall-cmd --zone=trusted --remove-interface="$iface" >/dev/null 2>&1 || true
    fi
}

module_parameter() {
    [[ -r /sys/module/iwlmvm/parameters/lar_disable ]] || return 1
    grep -Eq '^(Y|1)$' /sys/module/iwlmvm/parameters/lar_disable
}

find_override_for_kver() { # $1=kver -> prints first matching override path
    local kver=$1 ext
    for ext in ko ko.xz ko.zst ko.gz; do
        if [[ -e /lib/modules/$kver/updates/iwlmvm.$ext ]]; then
            printf '/lib/modules/%s/updates/iwlmvm.%s' "$kver" "$ext"
            return 0
        fi
    done
    return 1
}

# Extract lowercase GNU Build-ID hex string from a module file (.ko/.ko.xz/.ko.zst/.ko.gz)
file_build_id() {
    local f=$1 tmp='' bid=''
    [[ -r $f ]] || return 0
    case $f in
        *.ko)
            bid=$(readelf -n "$f" 2>/dev/null | awk '/Build ID:/{print $3; exit}' || true)
            ;;
        *.ko.xz|*.ko.zst|*.ko.gz)
            tmp=$(mktemp)
            case $f in
                *.ko.xz)  xz -dc "$f"   > "$tmp" 2>/dev/null || true ;;
                *.ko.zst) zstd -dc "$f" > "$tmp" 2>/dev/null || true ;;
                *.ko.gz)  gzip -dc "$f" > "$tmp" 2>/dev/null || true ;;
            esac
            bid=$(readelf -n "$tmp" 2>/dev/null | awk '/Build ID:/{print $3; exit}' || true)
            rm -f -- "$tmp"
            ;;
    esac
    printf '%s' "$bid"
}

# Extract lowercase GNU Build-ID hex string from loaded kernel module sysfs note
runtime_build_id() {
    local note=/sys/module/iwlmvm/notes/.note.gnu.build-id
    [[ -r $note ]] || return 0
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$note" 2>/dev/null <<'PYEOF' || true
import struct, sys
data = open(sys.argv[1], "rb").read()
if len(data) >= 12:
    namesz, descsz, ntype = struct.unpack("<III", data[:12])
    off = 12 + ((namesz + 3) & ~3)
    print(data[off:off + descsz].hex(), end="")
PYEOF
    else
        od -An -tx1 -j16 "$note" 2>/dev/null | tr -d ' \n' || true
    fi
}

# Overrides installed for kernels other than the running one: the classic
# "built it, then booted another kernel" trap (pinned GRUB default, or booting
# an older kernel on purpose for out-of-tree drivers).
other_overrides() {
    local f k
    for f in /lib/modules/*/updates/iwlmvm.ko /lib/modules/*/updates/iwlmvm.ko.*; do
        [[ -e $f ]] || continue
        k=${f#/lib/modules/}
        k=${k%%/*}
        [[ $k == "$KVER" ]] && continue
        printf '%s\n' "$k"
    done | sort -u
}

kernel_mismatch_note() {
    local o list=''
    while read -r o; do
        [[ -n $o ]] || continue
        list+="${list:+, }$o"
    done < <(other_overrides)
    [[ -n $list ]] || return 0
    printf 'WARN: patched iwlmvm is installed for %s, but this kernel is %s\n' \
        "$list" "$KVER" >&2
    printf '%s\n' \
        '      the override only loads on the kernel it was built for;' \
        '      rebuild for the running kernel: sudo ./install.sh (in the repo), then reboot' >&2
}

regdom_content() {
    local country=${1:-$(configured_country)}
    printf '%s\n' \
        '# Kernel regulatory domain used by patched, non-self-managed iwlmvm.' \
        "options cfg80211 ieee80211_regdom=$country"
}

regdom_is_ours() {
    local c
    c=$(configured_country)
    [[ $c =~ ^[A-Z]{2}$ ]] || return 1
    cmp -s "$REGDOM" <(regdom_content "$c")
}

dropin_content() {
    printf '%s\n' \
        '[Unit]' \
        'Wants=network-online.target' \
        'After=network-online.target' \
        'ConditionPathExists=/sys/module/iwlmvm/parameters/lar_disable' \
        'StartLimitIntervalSec=60' \
        'StartLimitBurst=3' \
        '' \
        '[Service]' \
        "ExecCondition=/usr/bin/grep -Eq '^(Y|1)$' /sys/module/iwlmvm/parameters/lar_disable"
}
dropin_is_ours() { cmp -s "$DROPIN" <(dropin_content); }

cmd_status() {
    local failed=0 selected override_path sel_real tgt_real
    local selected_srcversion runtime_srcversion selected_bid runtime_bid
    local country regdom others ch149_line
    country=$(configured_country)
    override_path=$(find_override_for_kver "$KVER" || printf '%s' "$TARGET")
    selected=$(modinfo -k "$KVER" -F filename iwlmvm 2>/dev/null || true)
    selected_srcversion=$(modinfo -k "$KVER" -F srcversion iwlmvm 2>/dev/null || true)
    runtime_srcversion=$(cat /sys/module/iwlmvm/srcversion 2>/dev/null || true)
    selected_bid=$(file_build_id "$selected")
    runtime_bid=$(runtime_build_id)
    regdom=$(iw reg get 2>/dev/null || true)
    others=$(other_overrides | paste -sd', ' - || true)
    ch149_line=$(iw list 2>/dev/null | grep -m1 '5745\.0 MHz \[149\]' | sed 's/^[[:space:]]*//' || true)

    printf 'kernel=%s\nselected=%s\nselected_build_id=%s\nruntime_build_id=%s\n' \
        "$KVER" \
        "${selected:-missing}" \
        "${selected_bid:-unavailable}" \
        "${runtime_bid:-unavailable}"
    if [[ -n $selected_srcversion || -n $runtime_srcversion ]]; then
        printf 'selected_srcversion=%s\nruntime_srcversion=%s\n' \
            "${selected_srcversion:-missing}" \
            "${runtime_srcversion:-missing}"
    fi
    local svc_en svc_act
    svc_en=$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)
    svc_act=$(systemctl is-active "$SERVICE" 2>/dev/null || true)
    printf 'loaded_parameter=%s\nregdom_country=%s\n5ghz_ch149=%s\noverride_other_kernels=%s\nservice=%s/%s\n' \
        "$(cat /sys/module/iwlmvm/parameters/lar_disable 2>/dev/null || echo missing)" \
        "$country" \
        "${ch149_line:-unknown}" \
        "${others:-none}" \
        "${svc_en:-not-found}" \
        "${svc_act:-inactive}"

    sel_real=$(readlink -f -- "${selected:-}" 2>/dev/null || true)
    tgt_real=$(readlink -f -- "$override_path" 2>/dev/null || true)
    if [[ -z $sel_real || ! -e $override_path || $sel_real != "$tgt_real" ]]; then
        printf 'FAIL: override not selected\n' >&2
        failed=1
    fi

    # Verify the currently loaded module matches the selected override:
    # prefer GNU Build-ID (works on Fedora & Ubuntu), fall back to srcversion.
    if [[ -n $selected_bid && -n $runtime_bid ]]; then
        if [[ $runtime_bid != "$selected_bid" ]]; then
            printf 'FAIL: running driver is not the selected override; reboot or run: sudo %s reload\n' "$0" >&2
            failed=1
        fi
    elif [[ -n $selected_srcversion ]]; then
        if [[ $runtime_srcversion != "$selected_srcversion" ]]; then
            printf 'FAIL: running driver is not the selected override; reboot or run: sudo %s reload\n' "$0" >&2
            failed=1
        fi
    fi

    module_parameter || { printf 'FAIL: lar_disable is not enabled\n' >&2; failed=1; }
    grep -q "^country $country:" <<<"$regdom" || { printf 'FAIL: country %s absent in regulatory domain\n' "$country" >&2; failed=1; }
    grep -q '(self-managed)' <<<"$regdom" && { printf 'FAIL: phy remains self-managed (LAR still active)\n' >&2; failed=1; }

    if (( failed != 0 )); then
        kernel_mismatch_note
        return 1
    fi

    printf '%s\n' 'Runtime driver/regulatory checks PASS.'
    if svc_is_on; then
        ap_summary
    else
        printf '%s\n' \
            'Start it: hotspot-on' \
            "Autostart is OFF by design; optional later: sudo $0 enable"
    fi
}

cmd_reload() {
    need_root reload
    local override_path selected sel_real tgt_real country i
    override_path=$(find_override_for_kver "$KVER" || true)
    [[ -n $override_path ]] || die "no override installed for $KVER (run install.sh first)"
    selected=$(modinfo -k "$KVER" -F filename iwlmvm 2>/dev/null || true)
    sel_real=$(readlink -f -- "${selected:-}" 2>/dev/null || true)
    tgt_real=$(readlink -f -- "$override_path" 2>/dev/null || true)
    [[ -n $sel_real && $sel_real == "$tgt_real" ]] || die "override is not selected by depmod (selected: ${selected:-none})"

    country=$(configured_country)
    if ! svc_is_off; then
        printf 'stopping %s before reloading iwlmvm ...\n' "$SERVICE"
        cmd_stop
    fi

    printf 'reloading iwlmvm (Wi-Fi will disconnect briefly) ...\n'
    modprobe -r iwlmvm || die "could not unload iwlmvm (reboot instead)"
    if ! iw reg get 2>/dev/null | grep -q "^country $country:"; then
        iw reg set "$country" 2>/dev/null || true
    fi
    modprobe iwlmvm || die "failed to load patched iwlmvm (check dmesg)"

    for i in $(seq 1 20); do
        if iw dev 2>/dev/null | grep -q 'type managed'; then
            break
        fi
        sleep 0.5
    done
    if ! iw reg get 2>/dev/null | grep -q "^country $country:"; then
        iw reg set "$country" 2>/dev/null || true
        sleep 0.5
    fi
    cmd_status
}

cmd_enable() {
    need_root enable
    cmd_status
    systemctl is-active --quiet "$SERVICE" || die "$SERVICE is not running (start it with hotspot-on first)"
    [[ ! -e $DROPIN ]] || die "drop-in already exists: $DROPIN"

    install -d -m 0755 "$(dirname "$DROPIN")"
    dropin_content > "$DROPIN.tmp"
    chmod 0644 "$DROPIN.tmp"
    mv "$DROPIN.tmp" "$DROPIN"
    if ! systemctl daemon-reload ||
       ! systemctl enable "$SERVICE" ||
       [[ $(systemctl show "$SERVICE" -p After --value) != *network-online.target* ]] ||
       [[ $(systemctl show "$SERVICE" -p StartLimitBurst --value) != 3 ]]; then
        systemctl disable "$SERVICE" || true
        rm -f "$DROPIN" "$DROPIN.tmp"
        systemctl daemon-reload || true
        die "could not configure safe hotspot autostart"
    fi
    printf '%s\n' \
        'Hotspot autostart enabled.' \
        'It waits for network-online and skips cleanly without patched iwlmvm.'
}

cmd_rollback() {
    need_root rollback
    local f
    if [[ -e $REGDOM ]]; then
        regdom_is_ours || die "refusing to remove modified config: $REGDOM"
    fi
    if [[ -e $DROPIN ]]; then
        dropin_is_ours || die "refusing to remove modified drop-in: $DROPIN"
    fi
    for f in /usr/local/bin/hotspot-on /usr/local/bin/hotspot-off /usr/local/bin/hotspot-status /usr/local/bin/hotspot-setting; do
        if [[ -e $f ]]; then
            grep -q '^# hotspot-linux managed' "$f" ||
                die "refusing to remove modified command: $f"
        fi
    done
    systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
    firewalld_revoke_ap ap0
    rm -f /lib/modules/"$KVER"/updates/iwlmvm.ko /lib/modules/"$KVER"/updates/iwlmvm.ko.* "$TARGET_TMP"
    rm -f "$REGDOM" "$REGDOM.tmp"
    rm -f "$DROPIN" "$DROPIN.tmp"
    rm -f /usr/local/bin/hotspot-on /usr/local/bin/hotspot-off /usr/local/bin/hotspot-status /usr/local/bin/hotspot-setting
    rmdir "$(dirname "$DROPIN")" 2>/dev/null || true
    systemctl daemon-reload
    depmod "$KVER"
    printf '%s\n' \
        'Rollback staged. Hotspot autostart remains disabled.' \
        'Reboot (or run: sudo modprobe -r iwlmvm && sudo modprobe iwlmvm) to load the distro driver.'
}

cmd_verify() {
    local override_path srcv rsrcv bid rbid
    override_path=$(find_override_for_kver "$KVER" || true)
    [[ -n $override_path ]] || die "no override installed for $KVER"
    sha256sum "$override_path"
    bid=$(file_build_id "$override_path")
    rbid=$(runtime_build_id)
    printf 'installed_build_id=%s\nruntime_build_id=%s\n' "${bid:-unavailable}" "${rbid:-unavailable}"
    srcv=$(modinfo -F srcversion "$override_path" 2>/dev/null || true)
    rsrcv=$(cat /sys/module/iwlmvm/srcversion 2>/dev/null || true)
    if [[ -n $srcv || -n $rsrcv ]]; then
        printf 'installed_srcversion=%s\nruntime_srcversion=%s\n' "${srcv:-missing}" "${rsrcv:-missing}"
    fi
}

ap_summary() {
    local iface ch freq ssid n gw chan='channel: unknown'
    iface=$(ap_iface)
    ch=$(iw dev "$iface" info 2>/dev/null | awk '$1=="channel"{print $2; exit}' || true)
    freq=$(iw dev "$iface" info 2>/dev/null | awk '$1=="channel"{gsub(/[()]/,"",$3); print $3; exit}' || true)
    ssid=$(iw dev "$iface" info 2>/dev/null | awk '$1=="ssid"{sub(/^[[:space:]]*ssid[[:space:]]+/, ""); print; exit}' || true)
    n=$(iw dev "$iface" station dump 2>/dev/null | grep -c '^Station' || true)
    gw=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}' || true)
    if [[ -n $ch ]]; then
        chan=$(printf 'channel %s (%s MHz)' "$ch" "${freq:-?}")
    fi
    printf 'hotspot is ON — %s%s: %s client(s), %s%s\n' \
        "$iface" \
        "${ssid:+ (SSID: $ssid)}" \
        "${n:-0}" \
        "$chan" \
        "${gw:+, IP: ${gw%/*}}"
}

cmd_start() {
    if svc_is_on; then
        ap_summary
        return 0
    fi
    need_root start
    # Verify create_ap.service exists
    systemctl cat "$SERVICE" >/dev/null 2>&1 ||
        die "$SERVICE is not installed; run sudo ./install.sh to install create_ap"
    [[ -f $CONF ]] ||
        die "missing $CONF; run sudo ./install.sh or copy config/create_ap.conf.example to $CONF"

    # Break any restart loop / stale state before a clean start
    systemctl stop "$SERVICE" 2>/dev/null || true
    systemctl reset-failed "$SERVICE" 2>/dev/null || true

    if ! module_parameter; then
        kernel_mismatch_note
        die "patched iwlmvm is not active (lar_disable missing/off).
    install + reboot (or sudo $0 reload) first, then check: hotspot-status"
    fi

    align_channel
    firewalld_allow_ap ap0

    systemctl start "$SERVICE"
    local i ok=0 iface
    for i in $(seq 1 40); do
        iface=$(ap_iface)
        # Ready only when the channel is actually programmed on the AP interface
        if iw dev "$iface" info 2>/dev/null | grep -q '^[[:space:]]*channel'; then
            firewalld_allow_ap "$iface"
            ok=1
            break
        fi
        if svc_is_off; then
            break
        fi
        sleep 0.5
    done
    if (( ok == 0 )); then
        systemctl stop "$SERVICE" 2>/dev/null || true
        systemctl reset-failed "$SERVICE" 2>/dev/null || true
        firewalld_revoke_ap ap0
        die "AP interface did not come up; last lines:
$(journalctl -b -u "$SERVICE" --no-pager -o cat 2>/dev/null | tail -n 12)
full log: journalctl -b -u $SERVICE --no-pager"
    fi
    ap_summary
}

cmd_stop() {
    if svc_is_off; then
        if (( EUID == 0 )); then
            systemctl reset-failed "$SERVICE" 2>/dev/null || true
            firewalld_revoke_ap ap0
        fi
        printf '%s\n' 'hotspot is already OFF.'
        return 0
    fi
    need_root stop
    local iface
    iface=$(ap_iface)
    systemctl stop "$SERVICE"
    local i
    for i in $(seq 1 20); do
        svc_is_on || break
        sleep 0.5
    done
    systemctl reset-failed "$SERVICE" 2>/dev/null || true
    firewalld_revoke_ap "$iface"
    [[ $iface == ap0 ]] || firewalld_revoke_ap ap0
    if ! svc_is_off; then
        die "failed to stop $SERVICE; check: journalctl -b -u $SERVICE --no-pager"
    fi
    printf '%s\n' 'hotspot is OFF.'
}

cmd_setting() {
    local script_dir bin_file
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    bin_file=$script_dir/../bin/hotspot-setting
    [[ -x $bin_file ]] || die "missing $bin_file (run from the hotspot-linux repo)"
    exec "$bin_file" "$@"
}

cmd_install_cmds() {
    need_root install-cmds
    local script_dir bin_dir f dest
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    bin_dir=$(cd -- "$script_dir/../bin" && pwd -P)
    for f in hotspot-on hotspot-off hotspot-status hotspot-setting; do
        [[ -x $bin_dir/$f ]] || die "missing $bin_dir/$f (run from the hotspot-linux repo)"
    done
    install -d -m 0755 /usr/local/bin
    for f in hotspot-on hotspot-off hotspot-status hotspot-setting; do
        dest=/usr/local/bin/$f
        if [[ -e $dest ]]; then
            grep -q '^# hotspot-linux managed' "$dest" ||
                die "$dest exists and is not ours; remove it manually first"
        fi
        sed "s|@REPO@|$(dirname -- "$script_dir")|g" "$bin_dir/$f" > "$dest.tmp"
        chmod 0755 "$dest.tmp"
        mv "$dest.tmp" "$dest"
    done
    printf '%s\n' \
        'Installed: hotspot-on, hotspot-off, hotspot-status, hotspot-setting (in /usr/local/bin).' \
        'Start: hotspot-on  |  Stop: hotspot-off  |  Status: hotspot-status  |  Settings: hotspot-setting'
}

cmd=${1:-}
shift || true
case $cmd in
    status)       cmd_status ;;
    start)        cmd_start ;;
    stop)         cmd_stop ;;
    reload)       cmd_reload ;;
    setting)      cmd_setting "$@" ;;
    enable)       cmd_enable ;;
    rollback)     cmd_rollback ;;
    verify)       cmd_verify ;;
    install-cmds) cmd_install_cmds ;;
    *) die "usage: $0 {status|start|stop|reload|setting|enable|rollback|verify|install-cmds}" ;;
esac
