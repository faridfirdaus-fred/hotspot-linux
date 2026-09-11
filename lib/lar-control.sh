#!/usr/bin/env bash
# hotspot-linux — manage the patched iwlmvm install + hotspot autostart.
# Target kernel defaults to the running one; override with IWLWVM_LAR_KVER.
set -Eeuo pipefail

KVER=${IWLWVM_LAR_KVER:-$(uname -r)}
TARGET=/lib/modules/$KVER/updates/iwlmvm.ko
TARGET_TMP=$TARGET.tmp
REGDOM=/etc/modprobe.d/cfg80211-regdom.conf
SERVICE=create_ap.service
DROPIN=/etc/systemd/system/$SERVICE.d/iwlmvm-lar.conf

die()      { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "run with sudo: sudo $0 $1"; }

module_parameter() {
    [[ -r /sys/module/iwlmvm/parameters/lar_disable ]] || return 1
    grep -Eq '^(Y|1)$' /sys/module/iwlmvm/parameters/lar_disable
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
    local failed=0 selected selected_srcversion runtime_srcversion regdom
    selected=$(modinfo -k "$KVER" -F filename iwlmvm 2>/dev/null || true)
    selected_srcversion=$(modinfo -k "$KVER" -F srcversion iwlmvm 2>/dev/null || true)
    runtime_srcversion=$(cat /sys/module/iwlmvm/srcversion 2>/dev/null || true)
    regdom=$(iw reg get 2>/dev/null || true)
    printf 'kernel=%s\nselected=%s\nselected_srcversion=%s\nruntime_srcversion=%s\nloaded_parameter=%s\nservice=%s/%s\n' \
        "$KVER" \
        "${selected:-missing}" \
        "${selected_srcversion:-missing}" \
        "${runtime_srcversion:-missing}" \
        "$(cat /sys/module/iwlmvm/parameters/lar_disable 2>/dev/null || echo missing)" \
        "$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)" \
        "$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
    [[ $selected == "$TARGET" ]] || { printf 'FAIL: override not selected\n' >&2; failed=1; }
    [[ -n $runtime_srcversion && $runtime_srcversion == "$selected_srcversion" ]] ||
        { printf 'FAIL: running driver is not the selected override; reboot required\n' >&2; failed=1; }
    module_parameter || { printf 'FAIL: lar_disable is not enabled\n' >&2; failed=1; }
    grep -q '^country ID:' <<<"$regdom" || { printf 'FAIL: country ID absent\n' >&2; failed=1; }
    grep -q '(self-managed)' <<<"$regdom" && { printf 'FAIL: phy remains self-managed\n' >&2; failed=1; }
    (( failed == 0 )) || return 1
    printf '%s\n' \
        'Runtime driver/regulatory checks PASS.' \
        "Manual start: sudo systemctl start $SERVICE" \
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
    for f in /usr/local/bin/hotspot-on /usr/local/bin/hotspot-off; do
        if [[ -e $f ]]; then
            grep -q '^# hotspot-linux managed' "$f" ||
                die "refusing to remove modified command: $f"
        fi
    done
    systemctl disable --now "$SERVICE" || true
    rm -f "$TARGET" "$TARGET_TMP"
    rm -f "$REGDOM" "$REGDOM.tmp"
    rm -f "$DROPIN" "$DROPIN.tmp"
    rm -f /usr/local/bin/hotspot-on /usr/local/bin/hotspot-off
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
    if systemctl is-active --quiet "$SERVICE"; then
        ap_summary
        return 0
    fi
    need_root start
    module_parameter || die "patched iwlmvm is not active (lar_disable missing/off).
    install + reboot first, then check: $0 status"
    systemctl start "$SERVICE"
    local i
    for i in $(seq 1 40); do
        iw dev ap0 info >/dev/null 2>&1 && break
        sleep 0.5
    done
    if ! iw dev ap0 info >/dev/null 2>&1; then
        die "ap0 did not come up; check: journalctl -b -u $SERVICE --no-pager"
    fi
    ap_summary
}

cmd_stop() {
    if ! systemctl is-active --quiet "$SERVICE"; then
        printf '%s\n' 'hotspot is already OFF.'
        return 0
    fi
    need_root stop
    systemctl stop "$SERVICE"
    local i
    for i in $(seq 1 20); do
        systemctl is-active --quiet "$SERVICE" || break
        sleep 0.5
    done
    if systemctl is-active --quiet "$SERVICE"; then
        die "failed to stop $SERVICE; check: journalctl -b -u $SERVICE --no-pager"
    fi
    printf '%s\n' 'hotspot is OFF.'
}

case ${1:-} in
    status)   cmd_status ;;
    start)    cmd_start ;;
    stop)     cmd_stop ;;
    enable)   cmd_enable ;;
    rollback) cmd_rollback ;;
    verify)   cmd_verify ;;
    *) die "usage: $0 {status|start|stop|enable|rollback|verify}" ;;
esac
