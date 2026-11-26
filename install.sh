#!/usr/bin/env bash
# hotspot-linux — patched iwlmvm (LAR disabled) installer for Fedora & Ubuntu.
# Enables 5 GHz AP mode (hotspot) on Intel Wi-Fi 6 (AX201/AX200/...).
#
# Flow: preflight (Secure Boot, stock iwlmvm) -> install build/hotspot deps ->
# fetch & verify matching kernel source (Fedora SRPM GPG-verified / Ubuntu
# Launchpad SHA256-verified) -> prove unpatched build matches stock driver ->
# apply patches/lar_disable.patch -> build & verify patched iwlmvm.ko ->
# install override + regdom + create_ap + /etc/create_ap.conf + CLI wrappers.
#
# Safe by design: hotspot autostart stays OFF; every failure is rolled back;
# a future kernel without the override simply loads the distro driver again.
set -Eeuo pipefail

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [options]

Options:
  --force, --reinstall   Safely replace an existing override for the running kernel
  --country CC           2-letter regulatory country code (default: ID)
  --no-create-ap         Skip installing create_ap / seeding /etc/create_ap.conf
  -h, --help             Show this help
EOF
}

FORCE=0
COUNTRY=${HOTSPOT_COUNTRY:-ID}
INSTALL_CREATE_AP=1
ORIG_ARGS=("$@")

while (( $# > 0 )); do
    case $1 in
        --force|--reinstall) FORCE=1; shift ;;
        --country)
            (( $# >= 2 )) || die "--country requires a 2-letter code (e.g. ID, US, GB)"
            COUNTRY=${2^^}; shift 2 ;;
        --no-create-ap) INSTALL_CREATE_AP=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try: $0 --help)" ;;
    esac
done

[[ $COUNTRY =~ ^[A-Z]{2}$ ]] || die "invalid --country '$COUNTRY' (expected 2 uppercase letters, e.g. ID)"
[[ $EUID -eq 0 ]] || exec sudo -E bash -- "$0" "${ORIG_ARGS[@]}"

KVER=$(uname -r)
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PATCH=$REPO/patches/lar_disable.patch
CONTROL=$REPO/lib/lar-control.sh
WORK=${IWLWVM_LAR_WORK:-/var/tmp/hotspot-linux}
TREE=$WORK/src
SERVICE=create_ap.service
CONF=/etc/create_ap.conf
TARGET=/lib/modules/$KVER/updates/iwlmvm.ko
REGDOM=/etc/modprobe.d/cfg80211-regdom.conf
BIN_ON=/usr/local/bin/hotspot-on
BIN_OFF=/usr/local/bin/hotspot-off
BIN_STATUS=/usr/local/bin/hotspot-status
BIN_SET=/usr/local/bin/hotspot-setting
CREATE_AP_TAG=${CREATE_AP_TAG:-v5.0.0}

[[ -s $PATCH ]] || die "missing $PATCH"
[[ -d /lib/modules/$KVER ]] || die "no /lib/modules/$KVER"

# ---- Preflight: distro, Secure Boot, stock iwlmvm -------------------------
. /etc/os-release
DISTRO=''
case ${ID:-} in
    fedora) DISTRO=fedora ;;
    ubuntu) DISTRO=ubuntu ;;
    *)
        if [[ " ${ID_LIKE:-} " == *" fedora "* ]]; then
            DISTRO=fedora
        elif [[ " ${ID_LIKE:-} " == *" ubuntu "* ]]; then
            DISTRO=ubuntu
        else
            die "unsupported distro: ${ID:-unknown} (supported: Fedora, Ubuntu)"
        fi
        ;;
esac

step "Preflight ($PRETTY_NAME | kernel $KVER)"

# Secure Boot check: unsigned out-of-tree module cannot load when Secure Boot is enforced
if command -v mokutil >/dev/null 2>&1; then
    sb_out=$(mokutil --sb-state 2>/dev/null || true)
    if grep -qi 'SecureBoot enabled' <<<"$sb_out"; then
        die "Secure Boot is enabled (mokutil: $sb_out).
    The rebuilt iwlmvm.ko is unsigned by design — disable Secure Boot in UEFI/BIOS first."
    fi
    info "Secure Boot: ${sb_out:-unknown}"
elif [[ -r /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c ]]; then
    sb_byte=$(od -An -tu1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | tr -d ' ' || echo 0)
    if [[ $sb_byte == 1 ]]; then
        die "Secure Boot is enabled (EFI SecureBoot=1). Disable Secure Boot in UEFI/BIOS first."
    fi
fi

# Locate stock iwlmvm module (supports .ko, .ko.xz, .ko.zst, .ko.gz)
STOCK_KO_SRC=''
for ext in ko ko.xz ko.zst ko.gz; do
    cand="/lib/modules/$KVER/kernel/drivers/net/wireless/intel/iwlwifi/mvm/iwlmvm.$ext"
    if [[ -r $cand ]]; then
        STOCK_KO_SRC=$cand
        break
    fi
done
[[ -n $STOCK_KO_SRC ]] || die "stock iwlmvm module not found under /lib/modules/$KVER/kernel/drivers/net/wireless/intel/iwlwifi/mvm/"
info "stock module: $STOCK_KO_SRC"

# Warn if running kernel is not the newest installed kernel
newest=$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n1 || true)
if [[ -n $newest && $newest != "$KVER" ]]; then
    info "note: $KVER is not the newest installed kernel ($newest)"
    info "      the override is built for the running kernel only — boot $KVER"
    info "      (or rebuild on $newest) to keep it active"
fi

decompress_ko() { # $1=src_ko $2=dest_raw_ko
    case $1 in
        *.ko)     cp -f -- "$1" "$2" ;;
        *.ko.xz)  xz -dc "$1"   > "$2" ;;
        *.ko.zst) zstd -dc "$1" > "$2" ;;
        *.ko.gz)  gzip -dc "$1" > "$2" ;;
        *)        die "unsupported module format: $1" ;;
    esac
}

mkdir -p "$WORK"
cd "$WORK"

# ---- Distro-specific deps + verified kernel source fetch ------------------
if [[ $DISTRO == fedora ]]; then
    step "Installing build & hotspot dependencies (dnf)"
    pkgs=(
        "kernel-devel-$KVER" gcc make patch elfutils-libelf-devel openssl-devel
        bc bison flex xz rpm-build cpio binutils curl
        hostapd dnsmasq iw iptables-nft procps-ng util-linux
    )
    dnf install -y -q "${pkgs[@]}"
    [[ -e /lib/modules/$KVER/build ]] || die "missing /lib/modules/$KVER/build (install kernel-devel-$KVER)"

    srpm=$(rpm -q --qf '%{SOURCERPM}\n' "kernel-core-$KVER" 2>/dev/null || true)
    [[ -n $srpm ]] || die "kernel-core-$KVER is not owned by an RPM package"
    nvr=${srpm%.src.rpm}
    k_ver=$(rpm -q --qf '%{VERSION}\n' "kernel-core-$KVER")
    k_rel=$(rpm -q --qf '%{RELEASE}\n' "kernel-core-$KVER")
    step "Source RPM: $srpm"

    if [[ ! -s $WORK/$srpm ]] || ! rpm -K "$WORK/$srpm" >/dev/null 2>&1; then
        rm -f "$WORK/$srpm"
        info "fetching $srpm via dnf source repos ..."
        if ! dnf download --source --destdir "$WORK" \
                --disablerepo='*' \
                --enablerepo=fedora-source \
                --enablerepo=updates-source \
                --enablerepo=updates-testing-source \
                "$nvr" 2>/dev/null; then
            koji_url="https://kojipkgs.fedoraproject.org/packages/kernel/$k_ver/$k_rel/src/$srpm"
            info "dnf source repo missed; trying Fedora Koji: $koji_url"
            curl -fL --retry 3 --retry-all-errors --connect-timeout 30 -C - "$koji_url" -o "$WORK/$srpm" ||
                die "could not download $srpm from dnf source repos or Koji"
        fi
    else
        info "ok (cached & verified): $srpm"
    fi

    step "Verifying SRPM GPG signature & SHA256 digests"
    rpm_sig=$(rpm -K "$WORK/$srpm") || die "SRPM verification failed: $srpm"
    info "$rpm_sig"
    grep -q 'digests signatures OK' <<<"$rpm_sig" ||
        die "SRPM signature not OK ($rpm_sig); refusing to build from untrusted source"

    step "Extracting iwlwifi driver source from $srpm"
    rm -rf "$WORK/srpm-unpack" "$TREE"
    mkdir -p "$WORK/srpm-unpack" "$TREE"
    (
        cd "$WORK/srpm-unpack"
        rpm2cpio "$WORK/$srpm" | cpio -idmu --quiet './linux-*.tar.xz' './patch-*.patch' 'linux-*.tar.xz' 'patch-*.patch' 2>/dev/null || true
    )
    tarball=$(find "$WORK/srpm-unpack" -maxdepth 1 -name 'linux-*.tar.xz' | head -n1 || true)
    [[ -s $tarball ]] || die "linux-*.tar.xz not found inside $srpm"
    tar_root=$(basename "$tarball" .tar.xz)
    tar -xJf "$tarball" -C "$TREE" --strip-components=1 "$tar_root/drivers/net/wireless/intel/iwlwifi"

    # Apply any Fedora/Red Hat kernel patch hunks that touch iwlwifi
    for pfile in "$WORK/srpm-unpack"/patch-*.patch; do
        [[ -s $pfile ]] || continue
        if grep -q 'drivers/net/wireless/intel/iwlwifi/' "$pfile"; then
            info "applying Fedora iwlwifi hunks from $(basename "$pfile")"
            python3 - "$pfile" "$WORK/fedora-iwlwifi.patch" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
keep = False
out = []
with open(src, "r", errors="replace") as f:
    for line in f:
        if line.startswith("diff --git ") or line.startswith("--- a/") or line.startswith("Index: "):
            if line.startswith("diff --git "):
                keep = "drivers/net/wireless/intel/iwlwifi/" in line
            elif not out or not out[-1].startswith("diff --git "):
                keep = "drivers/net/wireless/intel/iwlwifi/" in line
        if keep:
            out.append(line)
with open(dst, "w") as f:
    f.writelines(out)
PYEOF
            if [[ -s $WORK/fedora-iwlwifi.patch ]]; then
                ( cd "$TREE" && patch -p1 --silent < "$WORK/fedora-iwlwifi.patch" )
            fi
        fi
    done
    rm -rf "$WORK/srpm-unpack"
else
    # ---- Ubuntu path ----
    img=$(dpkg-query -S "/boot/vmlinuz-$KVER" 2>/dev/null | head -n1 | cut -d: -f1 || true)
    [[ -n ${img:-} ]] || die "kernel $KVER is not owned by any dpkg package"
    read -r _bin srcpkg ver < <(dpkg-query -W -f='${Package} ${Source} ${Version}\n' "$img")
    mods_src=$(dpkg-query -W -f='${Source}' "linux-modules-$KVER" 2>/dev/null || true)
    if [[ -n $mods_src ]]; then srcpkg=$mods_src; fi
    case $srcpkg in
        linux|linux-*) ;;
        linux-signed)   srcpkg=linux ;;
        linux-signed-*) srcpkg=linux-${srcpkg#linux-signed-} ;;
        *) die "unexpected source package: '$srcpkg' (image: $_bin)" ;;
    esac
    step "Source package: $srcpkg  version: $ver"

    step "Installing build & hotspot dependencies (apt)"
    command -v apt-get >/dev/null || die "apt-get not found"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        "linux-headers-$KVER" build-essential dpkg-dev patch bc bison flex \
        libssl-dev libelf-dev bzip2 zstd xz-utils curl \
        hostapd dnsmasq iw iptables procps
    [[ -e /lib/modules/$KVER/build ]] || die "missing /lib/modules/$KVER/build (install linux-headers-$KVER)"

    [[ ! -d $TREE ]] || rm -rf "$TREE"

    BASE="https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/$srcpkg/$ver"
    LPFILES="https://api.launchpad.net/1.0/ubuntu/+archive/primary/+files"
    POOL="http://archive.ubuntu.com/ubuntu/pool/main/l/$srcpkg"
    fetch_one() { # $1=sha256 $2=filename
        local want=$1 name=$2 have
        have=$(sha256sum "$name" 2>/dev/null | awk '{print $1}')
        [[ $have == "$want" ]] && { info "ok (cached): $name"; return 0; }
        for url in "$POOL/$name" "$LPFILES/$name" "$BASE/$name"; do
            info "trying $url"
            if curl -fL --retry 3 --retry-all-errors --connect-timeout 30 -C - "$url" -o "$name"; then
                have=$(sha256sum "$name" 2>/dev/null | awk '{print $1}')
                [[ $have == "$want" ]] && { info "verified: $name"; return 0; }
                info "checksum mismatch from $url; trying next mirror"
            fi
        done
        return 1
    }
    step "Downloading + SHA256-verifying source from Launchpad ($srcpkg $ver)"
    dsc="${srcpkg}_${ver}.dsc"
    curl -fL --retry 5 --retry-all-errors --connect-timeout 30 -C - "$BASE/$dsc" -o "$dsc"
    while read -r want name; do
        [[ -n $name ]] || continue
        fetch_one "$want" "$name" || die "could not fetch $name (sha256 $want)"
    done < <(awk '/^Checksums-Sha256:/{f=1;next} f && !/^ /{f=0} f{print $1, $3}' "$dsc")
    step "Extracting source tree (dpkg-source)"
    dpkg-source -x "$dsc" "$TREE" >/dev/null
fi

IWDIR=$TREE/drivers/net/wireless/intel/iwlwifi
[[ -s $IWDIR/mvm/ops.c && -s $IWDIR/mvm/mvm.h ]] ||
    die "source tree does not contain the iwlwifi/mvm driver: $TREE"

# ---- Compatibility Gate 1: Unpatched rebuild vs stock module --------------
step "Proving the source tree matches the stock module"
make -C "/lib/modules/$KVER/build" M="$IWDIR" modules -j"$(nproc)" >/dev/null
decompress_ko "$STOCK_KO_SRC" "$WORK/distro-stock.ko"
UNPATCHED_KO=$IWDIR/mvm/iwlmvm.ko
[[ -s $UNPATCHED_KO ]] || die "unpatched build did not produce iwlmvm.ko"

our_src=$(modinfo -F srcversion "$UNPATCHED_KO" 2>/dev/null || true)
stock_src=$(modinfo -F srcversion "$WORK/distro-stock.ko" 2>/dev/null || true)
if [[ -n $stock_src ]]; then
    info "unpatched build srcversion: ${our_src:-missing}"
    info "stock module     srcversion: $stock_src"
    [[ $our_src == "$stock_src" ]] ||
        die "rebuilt unpatched srcversion does not match the stock module ($our_src != $stock_src); refusing to install"
else
    # Kernels built without CONFIG_MODVERSIONS (e.g. Fedora) omit srcversion:
    # prove ABI compatibility by comparing vermagic, depends, import_ns, and full undefined symbol table.
    our_vm=$(modinfo -F vermagic "$UNPATCHED_KO")
    stock_vm=$(modinfo -F vermagic "$WORK/distro-stock.ko")
    [[ $our_vm == "$stock_vm" ]] || die "vermagic mismatch: '$our_vm' != '$stock_vm'"
    our_dep=$(modinfo -F depends "$UNPATCHED_KO")
    stock_dep=$(modinfo -F depends "$WORK/distro-stock.ko")
    [[ $our_dep == "$stock_dep" ]] || die "depends mismatch: '$our_dep' != '$stock_dep'"
    if ! diff -u <(nm -u "$WORK/distro-stock.ko" | sort) <(nm -u "$UNPATCHED_KO" | sort) >"$WORK/symdiff.txt"; then
        cat "$WORK/symdiff.txt" >&2
        die "unpatched build undefined symbols differ from stock module; refusing to install"
    fi
    info "vermagic, depends, and all $(nm -u "$UNPATCHED_KO" | wc -l) imported symbols match stock module 100%"
fi

# ---- Apply patch & build patched iwlmvm.ko --------------------------------
step "Applying patches/lar_disable.patch"
( cd "$TREE" && patch -p1 --silent < "$PATCH" )
grep -q 'lar_disable = true' "$IWDIR/mvm/ops.c" ||
    die "patch did not land in mvm/ops.c as expected"
grep -q 'iwlmvm_mod_params.lar_disable' "$IWDIR/mvm/mvm.h" ||
    die "patch did not land in mvm/mvm.h as expected"

step "Building patched iwlmvm for $KVER"
make -C "/lib/modules/$KVER/build" M="$IWDIR" modules -j"$(nproc)" >/dev/null
KO=$IWDIR/mvm/iwlmvm.ko
[[ -s $KO ]] || die "build did not produce iwlmvm.ko"
strip --strip-debug "$KO"

modinfo -p "$KO" | grep -Fq 'lar_disable:disable LAR (Location Aware Regulatory), default: true' ||
    die "built module lacks lar_disable=true default"
modinfo -F vermagic "$KO" | grep -Fq "$KVER" || die "vermagic does not match running kernel"

# ---- Compatibility Gate 2: Patched module imports vs stock ----------------
if readelf -S "$WORK/distro-stock.ko" 2>/dev/null | grep -q '__versions'; then
    python3 - "$KO" "$WORK/distro-stock.ko" <<'PYEOF' ||
import struct, subprocess, sys, tempfile

def crc_entries(path):
    with tempfile.NamedTemporaryFile() as tf:
        subprocess.run(["objcopy", "--dump-section", f"__versions={tf.name}", path],
                       check=True, capture_output=True)
        data = tf.read()
    out = {}
    for i in range(len(data) // 64):
        e = data[i*64:(i+1)*64]
        crc = struct.unpack("<Q", e[:8])[0]
        name = e[8:].split(b"\x00")[0].decode()
        out[name] = crc
    return out

ours = crc_entries(sys.argv[1])
stock = crc_entries(sys.argv[2])
bad = [k for k in ours if k in stock and ours[k] != stock[k]]
missing = [k for k in stock if k not in ours]
if bad or missing:
    print(f"CRC mismatches: {bad}")
    print(f"imports the stock module has but ours lacks: {missing}")
    sys.exit(1)
print(f"    import-CRC check: {len(stock)} common imports match, "
      f"{len(ours) - len(stock)} patch-added imports")
PYEOF
        die "import CRCs differ from the stock module - refusing to install"
else
    python3 - "$KO" "$WORK/distro-stock.ko" <<'PYEOF' ||
import subprocess, sys

def undef_syms(path):
    out = subprocess.check_output(["nm", "-u", path], text=True)
    return {line.split()[-1] for line in out.splitlines() if line.strip()}

ours = undef_syms(sys.argv[1])
stock = undef_syms(sys.argv[2])
missing = sorted(stock - ours)
added = sorted(ours - stock)
if missing:
    print(f"imports the stock module has but ours lacks: {missing}")
    sys.exit(1)
# Only param_ops_bool (from module_param_named(..., bool, ...)) should be added
unexpected = [s for s in added if s != "param_ops_bool"]
if unexpected:
    print(f"unexpected new imports: {unexpected}")
    sys.exit(1)
print(f"    symbol-table check: {len(stock)} stock imports preserved, added: {added or ['none']}")
PYEOF
        die "patched module symbol table check failed - refusing to install"
fi

BID=$(readelf -n "$KO" 2>/dev/null | awk '/Build ID:/{print $3; exit}' || true)
SRV=$(modinfo -F srcversion "$KO" 2>/dev/null || true)
SHA=$(sha256sum "$KO" | awk '{print $1}')
[[ -n $BID ]] && info "build_id=$BID"
[[ -n $SRV ]] && info "srcversion=$SRV"
info "sha256=$SHA"

# ---- Ensure create_ap + systemd unit + initial /etc/create_ap.conf --------
install_create_ap() {
    if ! command -v create_ap >/dev/null 2>&1 || ! systemctl cat "$SERVICE" >/dev/null 2>&1; then
        step "Installing create_ap CLI ($CREATE_AP_TAG from lakinduakash/linux-wifi-hotspot)"
        local raw_base="https://raw.githubusercontent.com/lakinduakash/linux-wifi-hotspot/$CREATE_AP_TAG/src/scripts"
        local fallback_base="https://raw.githubusercontent.com/lakinduakash/linux-wifi-hotspot/master/src/scripts"
        local stage=$WORK/create_ap_stage
        rm -rf "$stage"; mkdir -p "$stage"
        local f
        for f in create_ap create_ap.service bash_completion; do
            if ! curl -fsSL --retry 3 --connect-timeout 20 "$raw_base/$f" -o "$stage/$f"; then
                curl -fsSL --retry 3 --connect-timeout 20 "$fallback_base/$f" -o "$stage/$f" ||
                    die "could not fetch $f from lakinduakash/linux-wifi-hotspot"
            fi
        done
        grep -q '^#!/' "$stage/create_ap" || die "downloaded create_ap does not look like a script"
        grep -q '^\[Service\]' "$stage/create_ap.service" || die "downloaded create_ap.service is invalid"
        install -Dm0755 "$stage/create_ap" /usr/bin/create_ap
        install -Dm0644 "$stage/create_ap.service" /usr/lib/systemd/system/create_ap.service
        install -Dm0644 "$stage/bash_completion" /usr/share/bash-completion/completions/create_ap
        systemctl daemon-reload
        info "installed /usr/bin/create_ap and /usr/lib/systemd/system/create_ap.service"
    else
        info "create_ap and $SERVICE already installed"
    fi

    if [[ ! -e $CONF ]]; then
        step "Seeding $CONF from config/create_ap.conf.example"
        local iface ch freq band ht
        iface=$(iw dev 2>/dev/null | awk '$1=="Interface"{cur=$2} $1=="type" && $2=="managed"{print cur; exit}' || true)
        [[ -n $iface ]] || iface=wlan0
        ch=$(iw dev "$iface" info 2>/dev/null | awk '$1=="channel"{print $2; exit}' || true)
        freq=$(iw dev "$iface" info 2>/dev/null | awk '$1=="channel"{gsub(/[()]/,"",$3); print $3; exit}' || true)
        if [[ -n $ch && -n $freq ]]; then
            if (( freq < 3000 )); then band=2.4; else band=5; fi
        else
            ch=149; band=5
        fi
        case $ch in
            36|44|52|60|100|108|116|124|132|140|149|157) ht='[HT40+]' ;;
            40|48|56|64|104|112|120|128|136|144|153|161) ht='[HT40-]' ;;
            *) if [[ $band == 2.4 ]] && (( ch >= 1 && ch <= 7 )); then ht='[HT40+]'; elif [[ $band == 2.4 ]] && (( ch >= 8 && ch <= 13 )); then ht='[HT40-]'; else ht=''; fi ;;
        esac
        awk -v iface="$iface" -v ch="$ch" -v band="$band" -v country="$COUNTRY" -v ht="$ht" '
            /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
            /^WIFI_IFACE=/     { print "WIFI_IFACE=" iface; next }
            /^INTERNET_IFACE=/ { print "INTERNET_IFACE=" iface; next }
            /^CHANNEL=/        { print "CHANNEL=" ch; next }
            /^FREQ_BAND=/      { print "FREQ_BAND=" band; next }
            /^COUNTRY=/        { print "COUNTRY=" country; next }
            /^HT_CAPAB=/       { print "HT_CAPAB=" ht; next }
            { print }
        ' "$REPO/config/create_ap.conf.example" > "$CONF.tmp"
        chmod 0600 "$CONF.tmp"
        mv "$CONF.tmp" "$CONF"
        info "created $CONF (iface=$iface, band=${band}GHz, ch=$ch, country=$COUNTRY, mode 0600)"
        info "change default SSID/PASSPHRASE before use: hotspot-setting"
    else
        info "keeping existing $CONF"
    fi
}

if (( INSTALL_CREATE_AP )); then
    install_create_ap
fi

# ---- Install override + regdom + CLI commands (atomic w/ rollback) --------
step "Installing override (automatic rollback on any failure)"
if [[ -e $TARGET && $FORCE -eq 0 ]]; then
    die "override already installed: $TARGET
    reinstall in place : sudo $0 --force
    or remove it first : sudo $CONTROL rollback && sudo reboot"
fi

if [[ -e $REGDOM ]]; then
    if ! grep -q '^# Kernel regulatory domain used by patched, non-self-managed iwlmvm\.$' "$REGDOM"; then
        die "$REGDOM exists and is not ours; inspect and remove it manually"
    fi
fi

for f in "$BIN_ON" "$BIN_OFF" "$BIN_STATUS" "$BIN_SET"; do
    if [[ -e $f ]]; then
        grep -q '^# hotspot-linux managed' "$f" ||
            die "$f exists and is not ours; remove it manually first"
    fi
done

was_enabled=no; was_active=no; installed=no; configured=no; installed_cmds=no; had_prev=no
systemctl is-enabled --quiet "$SERVICE" 2>/dev/null && was_enabled=yes || true
systemctl is-active  --quiet "$SERVICE" 2>/dev/null && was_active=yes  || true
if [[ -e $TARGET ]]; then
    cp -a -- "$TARGET" "$TARGET.prev"
    had_prev=yes
fi

cleanup() {
    local rc=$?
    trap - EXIT
    if (( rc != 0 )); then
        rm -f "$TARGET.tmp" "$REGDOM.tmp" "$BIN_ON.tmp" "$BIN_OFF.tmp" "$BIN_STATUS.tmp" "$BIN_SET.tmp"
        if [[ $had_prev == yes ]]; then
            mv -f "$TARGET.prev" "$TARGET" 2>/dev/null || true
        elif [[ $installed == yes ]]; then
            rm -f "$TARGET"
        fi
        [[ $configured == yes ]] && rm -f "$REGDOM"
        [[ $installed_cmds == yes ]] && rm -f "$BIN_ON" "$BIN_OFF" "$BIN_STATUS" "$BIN_SET" || true
        depmod "$KVER" 2>/dev/null || true
        [[ $was_enabled == yes ]] && systemctl enable "$SERVICE" >/dev/null 2>&1 || true
        [[ $was_active  == yes ]] && systemctl start  "$SERVICE" >/dev/null 2>&1 || true
        printf 'Install failed; all changes rolled back.\n' >&2
    else
        rm -f "$TARGET.prev"
    fi
    exit "$rc"
}
trap cleanup EXIT

systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
install -d -m 0755 "$(dirname "$TARGET")"
install -m 0644 "$KO" "$TARGET.tmp"
mv "$TARGET.tmp" "$TARGET"; installed=yes

printf '%s\n' \
    '# Kernel regulatory domain used by patched, non-self-managed iwlmvm.' \
    "options cfg80211 ieee80211_regdom=$COUNTRY" > "$REGDOM.tmp"
chmod 0644 "$REGDOM.tmp"
mv "$REGDOM.tmp" "$REGDOM"; configured=yes
depmod "$KVER"

install -d -m 0755 /usr/local/bin
sed "s|@REPO@|$REPO|g" "$REPO/bin/hotspot-on"      > "$BIN_ON.tmp"
sed "s|@REPO@|$REPO|g" "$REPO/bin/hotspot-off"     > "$BIN_OFF.tmp"
sed "s|@REPO@|$REPO|g" "$REPO/bin/hotspot-status"  > "$BIN_STATUS.tmp"
sed "s|@REPO@|$REPO|g" "$REPO/bin/hotspot-setting" > "$BIN_SET.tmp"
chmod 0755 "$BIN_ON.tmp" "$BIN_OFF.tmp" "$BIN_STATUS.tmp" "$BIN_SET.tmp"
mv "$BIN_ON.tmp"     "$BIN_ON"
mv "$BIN_OFF.tmp"    "$BIN_OFF"
mv "$BIN_STATUS.tmp" "$BIN_STATUS"
mv "$BIN_SET.tmp"    "$BIN_SET"
installed_cmds=yes
info "commands installed: hotspot-on, hotspot-off, hotspot-status, hotspot-setting"

sel=$(modinfo -k "$KVER" -F filename iwlmvm 2>/dev/null || true)
sel_real=$(readlink -f -- "${sel:-}" 2>/dev/null || true)
tgt_real=$(readlink -f -- "$TARGET" 2>/dev/null || true)
[[ -n $sel_real && $sel_real == "$tgt_real" ]] ||
    die "override not selected by depmod (selected: ${sel:-none})"

rm -f "$TARGET.prev"
trap - EXIT

cat <<OUT

  Installed module : $TARGET
  Build ID         : ${BID:-n/a}
  srcversion       : ${SRV:-n/a (CONFIG_MODVERSIONS=n)}
  sha256           : $SHA
  Regulatory       : $REGDOM (country $COUNTRY)
  Hotspot config   : $CONF

  Next steps:
    1) Activate patched driver:
         sudo reboot
       (or live-reload without rebooting: sudo $CONTROL reload)
    2) hotspot-status                    # must report PASS
    3) hotspot-setting                   # set your SSID and passphrase
    4) hotspot-on                        # start hotspot (prompts for sudo)
    5) hotspot-off                       # stop it anytime
    6) (optional) autostart: sudo $CONTROL enable

  Rollback anytime:
    sudo $CONTROL rollback && sudo reboot
OUT
