#!/usr/bin/env bash
# hotspot-linux — manage the patched iwlmvm install + hotspot autostart.
# Target kernel defaults to the running one; override with IWLWVM_LAR_KVER.
# Preferred entry points are the hotspot-on/off/setting wrappers
# (installed to /usr/local/bin by install.sh / install-cmds).
set -Eeuo pipefail

KVER=${IWLWVM_LAR_KVER:-$(uname -r)}
TARGET=/lib/modules/$KVER/updates/iwlmvm.ko
TARGET_TMP=$TARGET.tmp
REGDOM=/etc/modprobe.d/cfg80211-regdom.conf
SERVICE=create_ap.service
CONF=${HOTSPOT_CONF:-/etc/create_ap.conf}
DROPIN=/etc/systemd/system/$SERVICE.d/iwlmvm-lar.conf

die()      { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "run with sudo: sudo $0 $1"; }

svc_state() { systemctl show "$SERVICE" -p ActiveState --value 2>/dev/null || echo unknown; }
svc_is_on() { [[ $(svc_state) == active ]]; }
svc_is_off() { local s; s=$(svc_state); [[ $s == inactive || $s == failed ]]; }

conf_get() { # $1=KEY -> last value, trimmed, dequoted
    local k=$1 v
    v=$(grep -E "^[[:space:]]*$k[[:space:]]*=" "$CONF" 2>/dev/null | tail -n 1 || true)
    v=${v#*=}
    v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}
    v=`printf "%s" "$v" | sed -e 's/^"//; s/"$//'`
    printf '%s' "$v"
}

conf_set() { # $1=KEY $2=value -> replace active lines or append
    local k=$1 v=$2
    if grep -Eq "^[[:space:]]*$k[[:space:]]*=" "$CONF"; then
        sed -i -E "s|^[[:space:]]*$k[[:space:]]*=.*|$k=$v|" "$CONF"
    else
        printf '%s=%s\n' "$k" "$v" >> "$CONF"
    fi
}

uplink_iface() {
    local w i
    w=$(conf_get WIFI_IFACE); i=$(conf_get INTERNET_IFACE)
    if [[ -n $w ]]; then printf '%s' "$w"
    elif [[ -n $i ]]; then printf '%s' "$i"
    else printf '%s' 'wlp0s20f3'
    fi
}

align_channel() {
    # Single radio: the AP must ride the station uplink's channel.
    # Syncs CHANNEL (and FREQ_BAND) in $CONF to the live uplink channel.
    local iface ch freq cfg_ch band
    [[ -f $CONF ]] || { printf 'WARN: missing %s; keeping requested channel\n' "$CONF" >&2; return 0; }
    iface=$(uplink_iface)
    ch=$(iw dev "$iface" info 2>/dev/null | awk '$1=="channel"{print $2; exit}' || true)
    freq=$(iw dev "$iface" info 2>/dev/null | awk '$1=="channel"{gsub(/[()]/,"",$3); print $3; exit}' || true)
    [[ -n $ch ]] || return 0  # uplink down/disconnected: keep configured channel
    cfg_ch=$(conf_get CHANNEL)
    if [[ $cfg_ch != "$ch" ]]; then
        cp -a -- "$CONF" "$CONF.bak-align"
        conf_set CHANNEL "$ch"
        if [[ -n $freq ]]; then
            if (( freq < 3000 )); then band=2.4; else band=5; fi
            conf_set FREQ_BAND "$band"
        fi
        printf 'aligning AP channel %s -> %s (uplink %s on channel %s%s)\n' \
            "${cfg_ch:-unset}" "$ch" "$iface" "$ch" "${freq:+ / $freq MHz}"
    fi
    return 0
}

module_parameter() {
    [[ -r /sys/module/iwlmvm/parameters/lar_disable ]] || return 1
    grep -Eq '^(Y|1)$' /sys/module/iwlmvm/parameters/lar_disable
}

# Overrides installed for kernels other than the running one: the classic
# "built it, then booted another kernel" trap (pinned GRUB default, or booting
# an older kernel on purpose for out-of-tree drivers).
other_overrides() {
    local f
    for f in /lib/modules/*/updates/iwlmvm.ko; do
        [[ -e $f ]] || continue
        [[ $f == "/lib/modules/$KVER/updates/iwlmvm.ko" ]] && continue
        printf '%s\n' "${f#/lib/modules/}"
    done
}

kernel_mismatch_note() {
    local o list=''
    while read -r o; do
        [[ -n $o ]] || continue
        list+="${list:+, }${o%%/*}"
    done < <(other_overrides)
    [[ -n $list ]] || return 0
    printf 'WARN: patched iwlmvm is installed for %s, but this kernel is %s\n' \
        "$list" "$KVER" >&2
    printf '%s\n' \
        '      the override only loads on the kernel it was built for;' \
        '      rebuild for the running kernel: sudo ./install.sh (in the repo), then reboot' >&2
}

regdom_content() {
    printf '%s\n' \
        '# Kernel regulatory domain used by patched, non-self-managed iwlmvm.' \
        'options cfg80211 ieee80211_regdom=ID'
}
regdom_is_ours() { cmp -s "$REGDOM" <(regdom_content); }

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
    local failed=0 selected selected_srcversion runtime_srcversion regdom others
    selected=$(modinfo -k "$KVER" -F filename iwlmvm 2>/dev/null || true)
    selected_srcversion=$(modinfo -k "$KVER" -F srcversion iwlmvm 2>/dev/null || true)
    runtime_srcversion=$(cat /sys/module/iwlmvm/srcversion 2>/dev/null || true)
    regdom=$(iw reg get 2>/dev/null || true)
    others=$(other_overrides | sed 's|/updates/iwlmvm.ko$||' | paste -sd', ' - || true)
    printf 'kernel=%s\nselected=%s\nselected_srcversion=%s\nruntime_srcversion=%s\nloaded_parameter=%s\noverride_other_kernels=%s\nservice=%s/%s\n' \
        "$KVER" \
        "${selected:-missing}" \
        "${selected_srcversion:-missing}" \
        "${runtime_srcversion:-missing}" \
        "$(cat /sys/module/iwlmvm/parameters/lar_disable 2>/dev/null || echo missing)" \
        "${others:-none}" \
        "$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)" \
        "$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
    [[ $selected == "$TARGET" ]] || { printf 'FAIL: override not selected\n' >&2; failed=1; }
    [[ -n $runtime_srcversion && $runtime_srcversion == "$selected_srcversion" ]] ||
        { printf 'FAIL: running driver is not the selected override; reboot required\n' >&2; failed=1; }
    module_parameter || { printf 'FAIL: lar_disable is not enabled\n' >&2; failed=1; }
    grep -q '^country ID:' <<<"$regdom" || { printf 'FAIL: country ID absent\n' >&2; failed=1; }
    grep -q '(self-managed)' <<<"$regdom" && { printf 'FAIL: phy remains self-managed\n' >&2; failed=1; }
    if (( failed != 0 )); then
        kernel_mismatch_note
        return 1
    fi
    printf '%s\n' \
        'Runtime driver/regulatory checks PASS.' \
        "Start it: hotspot-on" \
        "Autostart is OFF by design; optional later: sudo $0 enable"
}

cmd_enable() {
    need_root enable
    cmd_status
    systemctl is-active --quiet "$SERVICE" || die "$SERVICE is not running"
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
    if [[ -e $REGDOM ]]; then
        regdom_is_ours || die "refusing to remove modified config: $REGDOM"
    fi
    if [[ -e $DROPIN ]]; then
        dropin_is_ours || die "refusing to remove modified drop-in: $DROPIN"
    fi
    for f in /usr/local/bin/hotspot-on /usr/local/bin/hotspot-off /usr/local/bin/hotspot-setting; do
        if [[ -e $f ]]; then
            grep -q '^# hotspot-linux managed' "$f" ||
                die "refusing to remove modified command: $f"
        fi
    done
    systemctl disable --now "$SERVICE" || true
    rm -f "$TARGET" "$TARGET_TMP"
    rm -f "$REGDOM" "$REGDOM.tmp"
    rm -f "$DROPIN" "$DROPIN.tmp"
    rm -f /usr/local/bin/hotspot-on /usr/local/bin/hotspot-off /usr/local/bin/hotspot-setting
    rmdir "$(dirname "$DROPIN")" 2>/dev/null || true
    systemctl daemon-reload
    depmod "$KVER"
    printf '%s\n' \
        'Rollback staged. Hotspot autostart remains disabled.' \
        'Reboot to load the distro driver.'
}

cmd_verify() {
    [[ -e $TARGET ]] || die "no override installed for $KVER"
    sha256sum "$TARGET"
    printf 'installed_srcversion=%s\n' "$(modinfo -F srcversion "$TARGET")"
    printf 'runtime_srcversion=%s\n' "$(cat /sys/module/iwlmvm/srcversion 2>/dev/null || echo missing)"
}

ap_summary() {
    local ch freq n chan='channel: unknown'
    ch=$(iw dev ap0 info 2>/dev/null | awk '$1=="channel"{print $2; exit}' || true)
    freq=$(iw dev ap0 info 2>/dev/null | awk '$1=="channel"{gsub(/^\(/,"",$3); print $3; exit}' || true)
    n=$(iw dev ap0 station dump 2>/dev/null | grep -c '^Station' || true)
    if [[ -n $ch ]]; then
        chan=$(printf 'channel %s (%s MHz)' "$ch" "${freq:-?}")
    fi
    printf 'hotspot is ON — ap0: %s client(s), %s\n' "${n:-0}" "$chan"
}

cmd_start() {
    if svc_is_on; then
        ap_summary
        return 0
    fi
    need_root start
    # break any restart loop / stale state before a clean start
    systemctl stop "$SERVICE" 2>/dev/null || true
    systemctl reset-failed "$SERVICE" 2>/dev/null || true
    if ! module_parameter; then
        kernel_mismatch_note
        die "patched iwlmvm is not active (lar_disable missing/off).
    install + reboot first, then check: $0 status"
    fi
    align_channel
    systemctl start "$SERVICE"
    local i ok=0
    for i in $(seq 1 40); do
        # ready only when the channel is actually programmed on ap0
        if iw dev ap0 info 2>/dev/null | grep -q '^[[:space:]]*channel'; then
            ok=1; break
        fi
        if svc_is_off; then
            break
        fi
        sleep 0.5
    done
    if (( ok == 0 )); then
        systemctl stop "$SERVICE" 2>/dev/null || true
        systemctl reset-failed "$SERVICE" 2>/dev/null || true
        die "ap0 did not come up; last lines:\n$(journalctl -b -u "$SERVICE" --no-pager -o cat 2>/dev/null | tail -n 8)\nfull log: journalctl -b -u $SERVICE --no-pager"
    fi
    ap_summary
}

cmd_stop() {
    if svc_is_off; then
        systemctl reset-failed "$SERVICE" 2>/dev/null || true
        printf '%s\n' 'hotspot is already OFF.'
        return 0
    fi
    need_root stop
    systemctl stop "$SERVICE"
    local i
    for i in $(seq 1 20); do
        svc_is_on || break
        sleep 0.5
    done
    systemctl reset-failed "$SERVICE" 2>/dev/null || true
    if ! svc_is_off; then
        die "failed to stop $SERVICE; check: journalctl -b -u $SERVICE --no-pager"
    fi
    printf '%s\n' 'hotspot is OFF.'
}

cmd_setting() {
    # delegate to the wrapper (same validate + auto-restart logic); if we were
    # invoked by root directly, the wrapper skips its sudo re-exec (EUID == 0)
    local script_dir bin_dir
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    bin_dir=$script_dir/../bin/hotspot-setting
    [[ -x $bin_dir ]] || die "missing $bin_dir (run from the hotspot-linux repo)"
    exec "$bin_dir"
}

cmd_install_cmds() {
    need_root install-cmds
    local script_dir bin_dir f dest
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    bin_dir=$(cd -- "$script_dir/../bin" && pwd -P)
    for f in hotspot-on hotspot-off hotspot-setting; do
        [[ -x $bin_dir/$f ]] || die "missing $bin_dir/$f (run from the hotspot-linux repo)"
    done
    install -d -m 0755 /usr/local/bin
    for f in hotspot-on hotspot-off hotspot-setting; do
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
        'Installed: hotspot-on, hotspot-off, hotspot-setting (in /usr/local/bin).' \
        'Start with: hotspot-on   Stop with: hotspot-off   Settings: hotspot-setting'
}

case ${1:-} in
    status)       cmd_status ;;
    start)        cmd_start ;;
    stop)         cmd_stop ;;
    setting)      cmd_setting ;;
    enable)       cmd_enable ;;
    rollback)     cmd_rollback ;;
    verify)       cmd_verify ;;
    install-cmds) cmd_install_cmds ;;
    *) die "usage: $0 {status|start|stop|setting|enable|rollback|verify|install-cmds}" ;;
esac
