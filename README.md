# hotspot-linux

Enable 5 GHz AP mode (hotspot) on Intel Wi-Fi 6 (AX201/AX200/…) on **Fedora**
and **Ubuntu** by building a **patched `iwlmvm` kernel module** that disables
LAR (Location Aware Regulatory) and lets the kernel regulatory core
(`country ID` by default) manage channels instead of the driver/firmware.

Without the patch, hostapd fails with:
`IEEE 802.11 Hardware does not support configured channel` /
`Frequency 5745 not allowed for AP mode, flags: 0x2000`.

## What it does

1. Runs preflight checks (distro detection, **Secure Boot disabled**, stock
   `iwlmvm` module presence).
2. Fetches and cryptographically verifies the exact running kernel's source:
   - **Fedora**: downloads `kernel-<ver>-<rel>.src.rpm` via DNF source repos
     (Koji fallback), verifies RPM GPG signature + SHA256 digests (`rpm -K`),
     extracts `drivers/net/wireless/intel/iwlwifi`, and applies any Red Hat
     `iwlwifi` patch hunks.
   - **Ubuntu**: downloads the `.dsc` + source files from Launchpad/archive
     and SHA256-verifies every file before `dpkg-source -x`.
3. Proves the unpatched build matches the stock module (`srcversion` when
   `CONFIG_MODVERSIONS=y`; `vermagic`, `depends`, and full undefined symbol
   table when `CONFIG_MODVERSIONS=n`).
4. Applies `patches/lar_disable.patch` — adds module parameter `lar_disable`
   defaulting to `true` and returns `false` from `iwl_mvm_is_lar_supported()`,
   cleanly disabling LAR across init, mac80211 registration, scan, and D3
   resume paths.
5. Builds and strips `iwlmvm.ko`, verifies module metadata and symbol/CRC
   compatibility, and installs it to `/lib/modules/<kver>/updates/iwlmvm.ko`
   (kernel-specific override; a newer kernel without the override automatically
   falls back to the distro driver).
6. Sets `ieee80211_regdom=<country>` (default `ID`) via
   `/etc/modprobe.d/cfg80211-regdom.conf`.
7. Installs `create_ap` (CLI from `lakinduakash/linux-wifi-hotspot`),
   `hostapd`, `dnsmasq`, seeds `/etc/create_ap.conf` (mode `0600`) if missing,
   and installs the `hotspot-*` commands into `/usr/local/bin`.

Nothing is enabled at boot. The hotspot (`create_ap.service`) is intentionally
started **manually**. On Fedora, `firewalld` is handled automatically while the
hotspot is running (runtime `trusted` zone on the AP interface, revoked cleanly
on stop).

## Install (one command)

```bash
git clone git@github.com:faridfirdaus-fred/hotspot-linux.git
cd hotspot-linux
sudo ./install.sh
sudo reboot          # or live-reload: sudo lib/lar-control.sh reload
```

Options:
- `sudo ./install.sh --force` — safely reinstall/overwrite for the running kernel
- `sudo ./install.sh --country US` — set a different 2-letter regulatory country
- `sudo ./install.sh --no-create-ap` — build/install only the kernel module

Requirements: Fedora or Ubuntu, package-managed kernel, **Secure Boot
disabled** (the rebuilt module is unsigned — by design), internet access.

`install.sh` installs build and hotspot dependencies automatically and rolls
back all file changes if anything fails.

## After reboot (or reload)

```bash
hotspot-status                   # read-only check; must report PASS (no sudo)
hotspot-setting                  # edit SSID/passphrase (or --ssid / --pass / show)
hotspot-on                       # start the hotspot (prompts for sudo)
hotspot-off                      # stop it
```

`hotspot-on` is idempotent — when already running it prints a one-line
summary (interface, SSID, client count, channel, gateway IP). `hotspot-off` on
a stopped hotspot is a no-op. If the repo ever moves, the installed commands
still work (`systemctl` fallback) or can be pointed at the new location with
`HOTSPOT_LINUX_REPO=/new/path`.

Already installed the patched module the manual way? Install just the commands:

```bash
sudo lib/lar-control.sh install-cmds
```

`create_ap` reads `/etc/create_ap.conf` (see `config/create_ap.conf.example`).
`hotspot-on` automatically aligns `CHANNEL`, `FREQ_BAND`, and `HT_CAPAB`
(`[HT40+]` / `[HT40-]` / HT20) to your live Wi-Fi uplink channel (single radio:
the AP must ride the station's channel) and keeps a one-time backup at
`/etc/create_ap.conf.bak-align`.

## Changing SSID / password

Interactive editor:

```bash
hotspot-setting
```

Direct CLI update or inspect:

```bash
hotspot-setting show
hotspot-setting --ssid "My Hotspot" --pass "supersecret123"
hotspot-setting --hidden 1
```

Validates the config against `create_ap`'s actual `KEY=VALUE` parser (SSID
non-empty ≤32 bytes, passphrase 8–63 chars, no accidental literal quotes),
**auto-restarts the hotspot if it is running**, and prints the live SSID
afterwards. A broken edit is rejected and the original config is restored.

Note: `create_ap` does **not** strip quotes in `/etc/create_ap.conf` — spaces
work unquoted (`SSID=My Hotspot`), while wrapping a value in quotes broadcasts
literal quote characters.

## Hotspot autostart (optional)

Autostart is **OFF by design** — the hotspot only runs when you run
`hotspot-on`. If you ever want boot-time autostart:

```bash
sudo lib/lar-control.sh enable
```

This installs a systemd drop-in that waits for `network-online`, skips cleanly
on kernels without the patched module, and limits restart storms.

## Uninstall / roll back

```bash
sudo ./uninstall.sh   # removes override, regdom config, commands; then reboot
```

## Manage / diagnostics

```bash
hotspot-status                     # verify patch, Build-ID, regdom, 5 GHz ch149
sudo lib/lar-control.sh reload     # live-reload iwlmvm without full reboot
sudo lib/lar-control.sh verify     # installed module hash + Build-ID/srcversion
sudo lib/lar-control.sh rollback   # remove override + regdom config + commands
sudo reboot                        # distro driver loads again
```

Upgrading the kernel? The new kernel boots with the stock driver (no override
is installed for it). Re-run `sudo ./install.sh` from this repo after the
upgrade if you want the hotspot back on 5 GHz.

## Files

- `install.sh` — full installer (preflight → verify source → patch → build → install → `create_ap` → commands)
- `bin/hotspot-on` / `bin/hotspot-off` — start/stop the hotspot (installed to `/usr/local/bin`)
- `bin/hotspot-status` — read-only driver/regulatory/service health check
- `bin/hotspot-setting` — edit/show/set SSID & passphrase with validation + auto-restart
- `lib/lar-control.sh` — status / start / stop / reload / setting / enable / rollback / verify / install-cmds
- `patches/lar_disable.patch` — kernel patch adding `lar_disable=true` and gating `iwl_mvm_is_lar_supported()`
- `config/create_ap.conf.example` — hotspot config template

## Troubleshooting

Passwordless fast paths vs sudo prompt:

- `hotspot-status` → always read-only, **no password**.
- `hotspot-on` while already ON → prints the summary, **no password**.
- `hotspot-off` while already OFF → prints "already OFF", **no password**.
- Any real transition (start, stop, config edit) → elevates under `sudo`
  automatically.

### Common failures

- **`AP interface did not come up`** — check
  `journalctl -b -u create_ap.service --no-pager`. If it says
  `Frequency 5745 not allowed for AP mode` or
  `Hardware does not support configured channel`, run `hotspot-status` — it
  must report PASS. If your Wi-Fi uplink is on a DFS channel (52–144), switch
  your router/uplink to a non-DFS channel (e.g. 36–48 or 149–161) or 2.4 GHz.
- **`patched iwlmvm is not active (lar_disable missing/off)` although the
  override *is* installed** — you booted a kernel it was not built for.
  `hotspot-status` reports `override_other_kernels=…` and warns. Fix: boot the
  kernel you built for, or rebuild on the running kernel (`sudo ./install.sh`).
- **`override already installed`** during `install.sh` — use
  `sudo ./install.sh --force` to rebuild and replace in place, or run
  `sudo lib/lar-control.sh rollback` first.
- **Secure Boot error in preflight** — the rebuilt module is unsigned; disable
  Secure Boot in UEFI/BIOS (`mokutil --sb-state` must show `SecureBoot disabled`).
- **Clients connect on Fedora but get no IP / no internet** — `lar-control.sh`
  adds the AP interface to the `firewalld` `trusted` zone while the hotspot is
  active. Check `sudo firewall-cmd --zone=trusted --list-interfaces` while ON.
