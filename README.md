[![Download latest](https://img.shields.io/badge/🡇-Download_latest-green)](https://github.com/openwrt-xiaomi/xmir-patcher/archive/refs/heads/main.zip)
[![ViewCount](https://views.whatilearened.today/views/github/openwrt-xiaomi/xmir-patcher.svg)](https://github.com/openwrt-xiaomi/xmir-patcher/archive/refs/heads/main.zip)
[![Hits](https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2Fopenwrt-xiaomi%2Fxmir-patcher&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=hits&edge_flat=false)](https://github.com/openwrt-xiaomi/xmir-patcher/archive/refs/heads/main.zip)
[![Donations Page](https://github.com/andry81-cache/gh-content-static-cache/raw/master/common/badges/donate/donate.svg)](https://github.com/remittor/donate)

# XMiR-Patcher

XMiR-Patcher is a cross-platform toolkit that streamlines preparing and patching
Xiaomi router firmware. It bundles device unlock helpers, backup utilities, and
an automated build workflow for crafting custom ImmortalWrt images without
touching device bootloaders.

---

## Key features

* **Menu-driven launcher** – `run.sh`/`run.bat` provide a unified interface for
  every supported action, including device information, language packs, and the
  build manager.
* **Safety-first build automation** – `build_manager.py` orchestrates the full
  Redmi AX5400 (RA74) ImmortalWrt workflow with dry-run toggles, colorised
  logging, and resumable stages.
* **Comprehensive backups** – streamed SSH dumps of critical NAND partitions and
  checksum generation help you maintain reliable fallbacks.
* **Vendor blob integration** – pulls Qualcomm Wi-Fi/NSS firmware directly from
  the router and injects the assets into the ImmortalWrt `files/` overlay.
* **Dynamic RA74 web dashboard** – generates a lightweight status/config page
  that can ride on the stock MiWiFi/uHTTPd service or on an embedded busybox
  HTTP daemon with optional custom binaries.

---

## Requirements

* Python **3.8+**
* `openssl` (for crypto helpers)
* Typical build utilities (installed automatically by the build workflow when
  run on Ubuntu/Debian): `build-essential`, `gawk`, `git`, `gettext`,
  `libncurses5-dev`, `libssl-dev`, `xsltproc`, `zlib1g-dev`, `unzip`,
  `python3`, `rsync`.

---

## Getting started

### Windows

1. Ensure Python 3.8 or later is installed and available in `PATH`.
2. Double-click `run.bat` and follow the on-screen menu.

### Linux / macOS

```bash
chmod +x run.sh
./run.sh
```

The launcher will set up a virtual environment (if required) and expose the
same menu-driven interface as the Windows entrypoint.

---

## Build manager quick start

1. Launch the main menu (`run.sh` or `run.bat`).
2. Navigate to **Other functions → Launch build workflow manager**.
3. Configure environment overrides as needed (e.g.
   `export BUILD_ROUTER_HOST=192.168.1.190`).
4. Work through the numbered stages:
   * **Preflight** – verifies required binaries and workspace layout.
   * **Backups** – streams NAND partitions and generates checksums so you have a
     proven recovery path.
   * **Vendor assets** – syncs Wi-Fi/NSS blobs from the router into your
     workspace.
   * **Repository sync** – clones or updates ImmortalWrt, updates feeds, and
     applies the RA74 DTS/Makefile patches.
  * **Overlay preparation** – copies fetched blobs, writes first-boot scripts,
    installs the web dashboard assets, and makes executables ready for boot.
  * **Build** – launches `make menuconfig` followed by a parallel
    `make -j$(nproc)` compile.
  * **Artifact verification** – locates the newest `*ra74*sysupgrade*.bin` and
    records its SHA256 hash.

All stages honour the global `DRY_RUN=true` environment variable so you can
exercise the workflow without executing external commands.

### Router capability inventory

The repository ships `router_command_inventory.sh`, a self-contained utility
that inspects the commands present on the router and captures the associated
version strings. The build manager automatically drops it into the firmware
overlay at `/usr/sbin/ra74-command-inventory`, so every custom image exposes the
tool out of the box.

Run it locally on the router via SSH:

```sh
/usr/sbin/ra74-command-inventory
```

Or execute it from the build workspace against a remote shell:

```sh
scp router_command_inventory.sh root@192.168.1.190:/tmp/
ssh root@192.168.1.190 '/tmp/router_command_inventory.sh -o /tmp/command-inventory.txt'
scp root@192.168.1.190:/tmp/command-inventory.txt ./
```

Key behaviours:

* Scans `$PATH` for every executable and merges optional command lists supplied
  via `-c/--command` or `-f/--file`.
* Attempts common `--version`, `-V`, and `-v` flags; BusyBox applets inherit the
  BusyBox version banner automatically.
* Produces a clean table that includes each command name, its resolved path, and
  the detected version or `unknown` if the tool is silent.

---

## Best practices

* **Review generated files** – confirm DTS/Makefile updates and overlay content
  before flashing anything to hardware.
* **Validate checksums** – always compare the recorded SHA256 hash with the
  artifact you plan to transfer.
* **Keep fallbacks handy** – store stock firmware and your NAND dumps on a
  separate machine to simplify recovery.

---

## Custom web interface options

The build manager can bake a simple dashboard that surfaces live router
statistics and allows SSID tweaks without SSH access. Control its behaviour via
environment variables before launching `build_manager.py`:

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILD_WEB_STRATEGY` | `reuse` | Choose `reuse` to publish under `/www/ra74` using the stock MiWiFi/uHTTPd instance, or `standalone` to bundle a dedicated service under `/usr/share/ra74-web`. |
| `BUILD_WEB_PORT` | `8081` | Listening port for the standalone service (ignored when `reuse`). |
| `BUILD_WEB_BINARY` | *(blank)* | Optional path to a custom HTTP server binary on the build host. When provided, the binary is copied into `/usr/bin/ra74-httpd` and launched by the standalone service. |
| `BUILD_WEB_ARGS` | *(auto)* | Extra arguments passed to the standalone server. Use `{DOCROOT}` and `{PORT}` placeholders to interpolate runtime values. |

The generated page lives at `/www/ra74/index.html` (stock server) or the root
of the standalone service. JavaScript calls into `ra74_status.sh` for live JSON
metrics and `ra74_apply.sh` to push configuration updates. The standalone mode
ships an init script (`/etc/init.d/ra74-web`) so the service respawns via procd
after boot or crashes.

---

## Donations

[![Donations Page](https://github.com/andry81-cache/gh-content-static-cache/raw/master/common/badges/donate/donate.svg)](https://github.com/remittor/donate)
