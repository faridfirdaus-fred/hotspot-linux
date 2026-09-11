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

## Changing SSID / password

The easy way:

```bash
hotspot-setting
```

Opens `/etc/create_ap.conf` in nano (or `$VISUAL`/`$EDITOR`), then
validates (SSID non-empty ≤32 bytes, passphrase ≥8 chars, no unquoted
spaces, file still parses), **auto-restarts the hotspot if it is running**
and prints the live SSID afterwards. A broken edit is rejected and the
original config restored. Requires sudo when the hotspot is ON.

Manual way — both live in `/etc/create_ap.conf` (default install:
`SSID=MyAccessPoint`, `PASSPHRASE=12345678`):

```bash
sudo nano /etc/create_ap.conf   # edit the SSID= and PASSPHRASE= lines
hotspot-off && hotspot-on       # config is only read at start!
```

- Passphrase must be **at least 8 characters** or hostapd refuses to start.
- Avoid `=` inside the SSID; don't indent the lines.
- All clients disconnect once and re-auth with the new credentials — normal.
- No reinstall needed; the commands read the config on every start.
- Optional: set `HIDDEN=1` in the same file to hide the SSID from scans
  (clients must then add the network manually by typing the SSID).

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
- `lib/lar-control.sh` — status / start / stop / enable / rollback / verify / install-cmds
- `patches/lar_disable.patch` — the only kernel change (adds `lar_disable=true`)
- `config/create_ap.conf.example` — hotspot config template

## Troubleshooting

Passwordless fast paths vs sudo prompt (how the wrappers behave):

- `hotspot-on` while already ON → prints the summary, **no password**.
- `hotspot-off` while already OFF → prints "already OFF", **no password**.
- Any real transition (start or stop) → the wrapper runs itself under `sudo`
  automatically; you type your password once.
- Technically: the wrapper only checks `systemctl is-active` (read-only) and
  either runs `lib/lar-control.sh` directly or re-executes under `sudo`.
  It never parses output to decide, so it can't be fooled by locale.

Summary line right after `hotspot-on` may briefly show `0 client(s)` — clients
reconnect within seconds. The start command waits (up to 20 s) until ap0's
channel is actually programmed before reporting it.

### Common failures

- **`ERROR: run with sudo: sudo ... lar-control.sh <cmd>` printed by the
  control script itself** — you ran it directly without sudo. The
  `hotspot-on`/`hotspot-off` wrappers handle elevation for you; use them.
- **`hotspot is ON — ap0: N client(s), channel: unknown`** (fixed in
  `c5e23af`) — if your installed copy still shows this, refresh the commands:
  `cd ~/hotspot-linux && git pull && sudo lib/lar-control.sh install-cmds`.
- **`ap0 did not come up`** — check
  `journalctl -b -u create_ap.service --no-pager`. If it says
  `Frequency 5745 not allowed for AP mode` or
  `Hardware does not support configured channel`, the patched module is not
  loaded: run `sudo lib/lar-control.sh status` — it must say PASS; if it
  says "reboot required", you are on a kernel without the override
  (re-run `sudo ./install.sh` and reboot).
- **`override already installed` / `config already exists`** during
  `install.sh` — a previous install exists. Remove it first:
  `sudo lib/lar-control.sh rollback && sudo reboot`, then re-run
  `sudo ./install.sh`. (If the regdom config was changed by hand, rollback
  refuses and asks you to inspect it — intentional.)
- **`$f exists and is not ours`** for `hotspot-on`/`hotspot-off` — something
  else owns those names in `/usr/local/bin`; remove/replace it manually, the
  installer refuses to overwrite foreign files.
- **Secure Boot error in preflight** — the rebuilt module is unsigned;
  Secure Boot must be off (`mokutil --sb-state` shows
  `SecureBoot disabled`).
- **Wi-Fi uplink drops the hotspot channel** — the AP rides the station's
  channel; if your router moves the uplink (e.g. from 149 to another DFS
  channel), stop the hotspot (`hotspot-off`), reconnect, start again
  (`hotspot-on`). With `country ID` and LAR disabled the driver no longer
  self-manages channels, so 149 stays AP-capable.

