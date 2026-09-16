#!/usr/bin/env bash
# hotspot-linux — patched iwlmvm (LAR disabled) installer for Ubuntu.
# Enables 5 GHz AP mode (e.g. create_ap hotspot) on Intel Wi-Fi 6 (AX201).
#
# Flow: detect running kernel -> fetch matching Ubuntu source from Launchpad
# (SHA256-verified via .dsc) -> apply patches/lar_disable.patch -> build
# iwlmvm against running kernel headers -> install override + regdom=ID.
#
# Safe by design: hotspot autostart stays OFF; every failure is rolled back;
# a future kernel without the override simply loads the distro driver again.
set -Eeuo pipefail

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }

[[ $EUID -eq 0 ]] || exec sudo -E bash -- "$0" "$@"

KVER=$(uname -r)
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PATCH=$REPO/patches/lar_disable.patch
CONTROL=$REPO/lib/lar-control.sh
WORK=${IWLWVM_LAR_WORK:-/var/tmp/hotspot-linux}
TREE=$WORK/src
SERVICE=create_ap.service
TARGET=/lib/modules/$KVER/updates/iwlmvm.ko
REGDOM=/etc/modprobe.d/cfg80211-regdom.conf
BIN_ON=/usr/local/bin/hotspot-on
BIN_OFF=/usr/local/bin/hotspot-off
BIN_SET=/usr/local/bin/hotspot-setting

[[ -s $PATCH ]] || die "missing $PATCH"
[[ -d /lib/modules/$KVER ]] || die "no /lib/modules/$KVER"
. /etc/os-release
[[ ${ID:-} == ubuntu ]] || die "this installer targets Ubuntu (found: ${ID:-unknown})"

step "Kernel: $KVER"
img=$(dpkg-query -S "/boot/vmlinuz-$KVER" 2>/dev/null | head -n1 | cut -d: -f1 || true)
[[ -n ${img:-} ]] || die "kernel $KVER is not owned by any dpkg package"
read -r _bin srcpkg ver < <(dpkg-query -W -f='${Package} ${Source} ${Version}\n' "$img")
# The signed image's source (linux-signed[-<flavour>]) only carries the signing
# glue — the driver sources ship in the unsigned source package. Prefer the
# source of the modules package (that is the one the drivers come from), then
# map linux-signed[-X] -> linux[-X].
mods_src=$(dpkg-query -W -f='${Source}' "linux-modules-$KVER" 2>/dev/null || true)
if [[ -n $mods_src ]]; then srcpkg=$mods_src; fi
case $srcpkg in
  linux|linux-*) ;; # bare 'linux' and flavour'd names are the unsigned src pkgs
  linux-signed)   srcpkg=linux ;;
  linux-signed-*) srcpkg=linux-${srcpkg#linux-signed-} ;;
  *) die "unexpected source package: '$srcpkg' (image: $_bin)" ;;
esac
step "Source package: $srcpkg  version: $ver"

# A running kernel that is not the newest installed one (pinned GRUB default,
# manual boot) is exactly how the override ends up missing on the live kernel.
newest=$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n1 || true)
if [[ -n $newest && $newest != "$KVER" ]]; then
  info "note: $KVER is not the newest installed kernel ($newest)"
  info "      the override is built for the running kernel only — reboot into"
  info "      $KVER (or build again on the kernel you boot) to keep it active"
fi

mkdir -p "$WORK"; cd "$WORK"

step "Installing build dependencies"
if command -v apt-get >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    "linux-headers-$KVER" build-essential dpkg-dev patch bc bison flex \
    libssl-dev libelf-dev bzip2 zstd
else
  die "apt-get not found; install kernel headers and build tools manually"
fi
[[ -e /lib/modules/$KVER/build ]] || die "missing /lib/modules/$KVER/build (install linux-headers-$KVER)"

[[ ! -d $TREE ]] || rm -rf "$TREE"

# The archive's linux-source-<base> deb ships the *bare* upstream tarball
# (verified: its unpatched iwlmvm build neither matches the distro module's
# srcversion nor its code — the Debian patch set is missing). The authoritative
# source is the source package (.dsc + orig.tar.gz + debian patch diff) applied
# with dpkg-source; its unpatched rebuild reproduces the stock module's
# srcversion exactly (validated for 7.0.0-30.30).
BASE="https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/$srcpkg/$ver"
LPFILES="https://api.launchpad.net/1.0/ubuntu/+archive/primary/+files"
POOL="http://archive.ubuntu.com/ubuntu/pool/main/l/$srcpkg"
# Fast path first: the archive pool keeps the shared orig tarball (and often
# the current diff). Every file is sha256-gated against the signed .dsc, so
# the mirror choice is only about speed. Fallbacks: Launchpad +files (API,
# resumable, sometimes slow), then launchpad.net +sourcefiles.
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
[[ -s $TREE/drivers/net/wireless/intel/iwlwifi/mvm/ops.c ]] ||
  die "source tree does not contain the iwlwifi driver: $TREE"

# Prove the tree is the one the distro module was built from: an unpatched
# rebuild must reproduce the stock module's srcversion (a hash over every
# source/header file the module is built from).
step "Proving the source tree matches the stock module (srcversion)"
IWDIR=$TREE/drivers/net/wireless/intel/iwlwifi
make -C /lib/modules/$KVER/build M=$IWDIR modules -j"$(nproc)" >/dev/null
zstd -dc "/lib/modules/$KVER/kernel/drivers/net/wireless/intel/iwlwifi/mvm/iwlmvm.ko.zst" \
  > "$WORK/distro-stock.ko"
our_src=$(modinfo -F srcversion "$IWDIR/mvm/iwlmvm.ko")
stock_src=$(modinfo -F srcversion "$WORK/distro-stock.ko")
info "unpatched build srcversion: $our_src"
info "stock module     srcversion: $stock_src"
[[ $our_src == "$stock_src" ]] ||
  die "rebuilt unpatched srcversion does not match the stock module
    ($our_src != $stock_src) - this tree is not what the distro module was
    built from; refusing to install a module based on the wrong source"

step "Applying patches/lar_disable.patch"
( cd "$TREE" && patch -p1 --silent < "$PATCH" )
grep -q 'lar_disable = true' "$IWDIR/mvm/ops.c" ||
  die "patch did not land where expected"

step "Building iwlmvm for $KVER"
make -C /lib/modules/$KVER/build M=$IWDIR modules -j"$(nproc)" >/dev/null
KO=$IWDIR/mvm/iwlmvm.ko
[[ -s $KO ]] || die "build did not produce iwlmvm.ko"
modinfo -p "$KO" | grep -Fq 'lar_disable:disable LAR (Location Aware Regulatory), default: true' ||
  die "built module lacks lar_disable=true default"
modinfo -F vermagic "$KO" | grep -Fq "$KVER" || die "vermagic does not match running kernel"
# Modversions gate: every import CRC must equal the stock module's (the
# patched module may import *more*, e.g. param_ops_bool, but never different
# CRCs and never fewer). This catches a wrong kernel/config even when the
# vermagic string alone would pass.
zstd -dc "/lib/modules/$KVER/kernel/drivers/net/wireless/intel/iwlwifi/mvm/iwlmvm.ko.zst" \
  > "$WORK/distro-stock.ko"
python3 - "$KO" "$WORK/distro-stock.ko" <<'PYEOF' ||
import struct, subprocess, sys, tempfile, os

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
print(f"import-CRC check: {len(stock)} common imports match, "
      f"{len(ours) - len(stock)} patch-added imports")
PYEOF
  die "import CRCs differ from the stock module - refusing to install"
SRV=$(modinfo -F srcversion "$KO")
SHA=$(sha256sum "$KO" | awk '{print $1}')
info "srcversion=$SRV"
info "sha256=$SHA"

step "Installing override (automatic rollback on any failure)"
[[ ! -e $TARGET ]] || die "override already installed: $TARGET
    remove it first:  sudo $CONTROL rollback && sudo reboot"
if [[ -e $REGDOM ]]; then
  cmp -s "$REGDOM" <(printf '%s\n' \
    '# Kernel regulatory domain used by patched, non-self-managed iwlmvm.' \
    'options cfg80211 ieee80211_regdom=ID') ||
    die "$REGDOM exists and is not ours; inspect and remove it manually"
fi
for f in "$BIN_ON" "$BIN_OFF" "$BIN_SET"; do
  if [[ -e $f ]]; then
    grep -q '^# hotspot-linux managed' "$f" ||
      die "$f exists and is not ours; remove it manually first"
  fi
done
was_enabled=no; was_active=no; installed=no; configured=no; installed_cmds=no
systemctl is-enabled --quiet "$SERVICE" 2>/dev/null && was_enabled=yes || true
systemctl is-active  --quiet "$SERVICE" 2>/dev/null && was_active=yes  || true
cleanup() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    rm -f "$TARGET.tmp" "$REGDOM.tmp"
    [[ $installed  == yes ]] && rm -f "$TARGET"
    [[ $configured == yes ]] && rm -f "$REGDOM"
    [[ $installed_cmds == yes ]] && rm -f "$BIN_ON" "$BIN_OFF" "$BIN_SET" || true
    depmod "$KVER" 2>/dev/null || true
    [[ $was_enabled == yes ]] && systemctl enable  "$SERVICE" >/dev/null 2>&1 || true
    [[ $was_active  == yes ]] && systemctl start   "$SERVICE" >/dev/null 2>&1 || true
    printf 'Install failed; all changes rolled back.\n' >&2
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
  'options cfg80211 ieee80211_regdom=ID' > "$REGDOM.tmp"
chmod 0644 "$REGDOM.tmp"; mv "$REGDOM.tmp" "$REGDOM"; configured=yes
depmod "$KVER"

install -d -m 0755 /usr/local/bin
sed "s|@REPO@|$REPO|g" "$REPO/bin/hotspot-on"  > "$BIN_ON.tmp"
sed "s|@REPO@|$REPO|g" "$REPO/bin/hotspot-off" > "$BIN_OFF.tmp"
sed "s|@REPO@|$REPO|g" "$REPO/bin/hotspot-setting" > "$BIN_SET.tmp"
chmod 0755 "$BIN_ON.tmp" "$BIN_OFF.tmp" "$BIN_SET.tmp"
mv "$BIN_ON.tmp" "$BIN_ON"
mv "$BIN_OFF.tmp" "$BIN_OFF"
mv "$BIN_SET.tmp" "$BIN_SET"
installed_cmds=yes
info "commands installed: hotspot-on, hotspot-off, hotspot-setting"
trap - EXIT
sel=$(modinfo -k "$KVER" -F filename iwlmvm 2>/dev/null || true)
[[ $sel == "$TARGET" ]] || die "override not selected by depmod (selected: ${sel:-none})"

cat <<OUT

  Installed module : $TARGET
  srcversion       : $SRV
  sha256           : $SHA
  Regulatory       : $REGDOM (country ID)

  Next steps:
    1) sudo reboot
    2) sudo $CONTROL status              # must report PASS
    3) hotspot-on                        # start hotspot (prompts for sudo)
    4) hotspot-off                       # stop it anytime
    5) (optional) autostart: sudo $CONTROL enable

  Rollback anytime:
    sudo $CONTROL rollback && sudo reboot
OUT
