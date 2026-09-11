# hotspot-linux

Enable 5 GHz AP mode (hotspot) on Intel Wi-Fi 6 (AX201/AX200/…) on Ubuntu by
building a **patched `iwlmvm` kernel module** that disables LAR
(Location Aware Regulatory) and letting the kernel regulatory core
(`country ID`) manage channels instead of the driver/firmware.

Without the patch, hostapd fails with:
`IEEE 802.11 Hardware does not support configured channel` /
`Frequency 5745 not allowed for AP mode, flags: 0x2000`.

## What it does

1. Detects the **running** kernel and its Ubuntu source package
   (`linux-signed-hwe-7.0` → source `linux-hwe-7.0`, etc.).
2. Downloads the exact source from Launchpad and **SHA256-verifies** every
   file against the signed `.dsc` manifest.
3. Applies `patches/lar_disable.patch` — adds module parameter
   `lar_disable` defaulting to `true` (breaks the
   `REGULATORY_WIPHY_SELF_MANAGED` path, channel 149 etc. become AP-capable).
4. Builds `iwlmvm.ko` against the running kernel's headers and installs it to
   `/lib/modules/<kver>/updates/iwlmvm.ko` (kernel-specific override; a newer
   kernel without the override automatically falls back to the distro driver).
5. Sets `ieee80211_regdom=ID` via `/etc/modprobe.d/cfg80211-regdom.conf`.

Nothing is enabled at boot. The hotspot (`create_ap.service`) is intentionally
started **manually**.

## Install (one command)

```bash
git clone git@github.com:faridfirdaus-fred/hotspot-linux.git
cd hotspot-linux
sudo ./install.sh
sudo reboot
```

Requirements: Ubuntu, dpkg-managed kernel, **Secure Boot disabled**
(the rebuilt module is unsigned — by design), internet access.

`install.sh` installs build deps via apt automatically and rolls back all file
changes if anything fails.

## After reboot

```bash
sudo lib/lar-control.sh status   # must report PASS
hotspot-on                       # start the hotspot (prompts for sudo)
hotspot-off                      # stop it
```

`hotspot-on` is idempotent — when already running it prints a one-line
summary (client count + channel). `hotspot-off` on a stopped hotspot is a
no-op. If the repo ever moves, the installed commands still work (plain
`systemctl` fallback) or can be pointed at the new location with
`HOTSPOT_LINUX_REPO=/new/path`.

Already installed the patched module the manual way (override present, no
`hotspot-on` command yet)? Just install the commands:

```bash
sudo lib/lar-control.sh install-cmds
```

`create_ap` reads `/etc/create_ap.conf` (see `config/create_ap.conf.example`).
Client connects on the same 5 GHz channel as your station uplink (e.g.
channel 149), NAT-shared to the internet.

## Hotspot autostart (optional)

Autostart is **OFF by design** — the hotspot only runs when you run
`hotspot-on`. If you ever want boot-time autostart:

```bash
sudo lib/lar-control.sh enable
```

This installs a systemd drop-in that waits for `network-online`, skips cleanly
on kernels without the patched module, and limits restart storms.

## Uninstall

```bash
sudo ./uninstall.sh   # removes override, regdom config, commands; then reboot
```


## Manage / roll back

```bash
sudo lib/lar-control.sh status     # verify patch is active
sudo lib/lar-control.sh verify     # installed module hash + srcversions
sudo lib/lar-control.sh rollback   # remove override + regdom config
sudo reboot                        # distro driver loads again
```

Upgrading the kernel? The new kernel boots with the stock driver (no override
is installed for it). Re-run `sudo ./install.sh` from this repo after the
upgrade if you want the hotspot back on 5 GHz.

## Files

- `install.sh` — full installer (download → verify → patch → build → install → commands)
- `bin/hotspot-on` / `bin/hotspot-off` — start/stop the hotspot (installed to `/usr/local/bin`)
- `lib/lar-control.sh` — status / start / stop / enable / rollback / verify
- `patches/lar_disable.patch` — the only kernel change (adds `lar_disable=true`)
- `config/create_ap.conf.example` — hotspot config template
