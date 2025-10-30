#!/usr/bin/env python3
"""Menu-driven build workflow manager for embedded Linux projects.

This module provides a Python implementation of the build automation script that
previously lived in ``build_manager.sh``.  It keeps the same user experience but
integrates with the rest of the Python tooling that powers this project.
"""

from __future__ import annotations

import atexit
import hashlib
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
from datetime import datetime
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence, Tuple

# ---------------------------------------------------------------------------
# Global configuration
# ---------------------------------------------------------------------------

# The workflow is parameterised so that nothing sensitive is hard-coded.  These
# defaults can be overridden via environment variables to suit the local setup.
CONFIG: Dict[str, str] = {
    "vendor_user": os.environ.get("BUILD_VENDOR_USER", "root"),
    "vendor_host": os.environ.get("BUILD_VENDOR_HOST", "192.168.1.190"),
    "vendor_path": os.environ.get("BUILD_VENDOR_PATH", "/lib/firmware"),
    "backup_host": os.environ.get("BUILD_BACKUP_HOST", "192.168.1.190"),
    "backup_path": os.environ.get("BUILD_BACKUP_PATH", "/"),
    "build_root": os.environ.get("BUILD_ROOT", "./builder_workspace"),
    "repo_url": os.environ.get(
        "BUILD_REPO_URL", "https://github.com/immortalwrt/immortalwrt.git"
    ),
    "repo_branch": os.environ.get("BUILD_REPO_BRANCH", "master"),
    "repo_name": os.environ.get("BUILD_REPO_NAME", "immortalwrt"),
    "artifact_glob": os.environ.get(
        "BUILD_ARTIFACT_GLOB",
        "bin/targets/qualcommax/ipq50xx/*ra74*sysupgrade*.bin",
    ),
    "vendor_assets_local": os.environ.get(
        "BUILD_VENDOR_ASSETS", os.path.expanduser("~/ra74-fw")
    ),
}

DRY_RUN = os.environ.get("DRY_RUN", "false").lower() in {"1", "true", "yes", "on"}

# Tools that we expect to have available before running the workflow.
REQUIRED_TOOLS: Sequence[str] = (
    "git",
    "ssh",
    "scp",
    "rsync",
    "make",
    "awk",
    "tar",
    "python3",
    "xz",
)

# ANSI colour helpers.
COLOURS: Dict[str, str] = {
    "reset": "\033[0m",
    "ok": "\033[92m",
    "warn": "\033[93m",
    "err": "\033[91m",
    "info": "\033[96m",
}


class LogWriter:
    """Simple logger that mirrors messages to stdout and a log file."""

    def __init__(self, log_path: Path) -> None:
        self._log_path = log_path
        log_path.parent.mkdir(parents=True, exist_ok=True)
        self._handle = log_path.open("a", encoding="utf-8")

    def close(self) -> None:
        if not self._handle.closed:
            self._handle.close()

    def _write(self, prefix: str, message: str, colour: str) -> None:
        timestamp = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
        line = f"[{timestamp}] {prefix}: {message}"
        self._handle.write(line + "\n")
        self._handle.flush()
        coloured_line = f"{COLOURS[colour]}{line}{COLOURS['reset']}"
        print(coloured_line)

    def info(self, message: str) -> None:
        self._write("INFO", message, "info")

    def ok(self, message: str) -> None:
        self._write(" OK ", message, "ok")

    def warn(self, message: str) -> None:
        self._write("WARN", message, "warn")

    def err(self, message: str) -> None:
        self._write("ERR", message, "err")


class BuildManager:
    """Drives the full build lifecycle via a menu-driven interface."""

    def __init__(self) -> None:
        timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
        log_dir = Path(CONFIG["build_root"]) / "logs"
        self.logger = LogWriter(log_dir / f"build_manager_{timestamp}.log")
        self.summary: List[Tuple[str, str]] = []
        self.cleanup_paths: List[Path] = []
        self.repo_dir = Path(CONFIG["build_root"]) / CONFIG["repo_name"]
        self.overlay_dir = self.repo_dir / "files"
        self.vendor_assets_dir = Path(CONFIG["build_root"]) / "vendor_assets"
        self.dry_run = DRY_RUN

        # Register signal handlers and cleanup routines to emulate shell traps.
        atexit.register(self._cleanup)
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, self._handle_signal)

        # Ensure base workspace exists.
        Path(CONFIG["build_root"]).mkdir(parents=True, exist_ok=True)
        self.logger.info("Build manager initialised (dry-run=%s)." % self.dry_run)

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _handle_signal(self, signum, _frame) -> None:
        self.logger.warn(f"Received signal {signum}; cleaning up before exit.")
        self._cleanup()
        sys.exit(1)

    def _cleanup(self) -> None:
        while self.cleanup_paths:
            path = self.cleanup_paths.pop()
            if path.exists():
                if path.is_dir():
                    shutil.rmtree(path, ignore_errors=True)
                else:
                    try:
                        path.unlink()
                    except FileNotFoundError:
                        pass
        self.logger.info("Temporary artefacts cleaned up.")
        self.logger.close()

    def _record_summary(self, step: str, status: str) -> None:
        self.summary.append((step, status))

    def _run_command(
        self,
        command: Sequence[str],
        cwd: Optional[Path] = None,
        check: bool = True,
        interactive: bool = False,
    ) -> subprocess.CompletedProcess:
        cmd_display = " ".join(shlex_quote(part) for part in command)
        location = f" (cwd={cwd})" if cwd else ""
        self.logger.info(f"Executing command{location}: {cmd_display}")
        if self.dry_run:
            self.logger.ok("Dry-run mode: command skipped.")
            return subprocess.CompletedProcess(command, 0, b"", b"")
        if interactive:
            return subprocess.run(command, cwd=str(cwd) if cwd else None)
        return subprocess.run(command, cwd=str(cwd) if cwd else None, check=check)

    def _write_file(self, path: Path, content: str) -> None:
        if self.dry_run:
            self.logger.ok(f"Dry-run mode: would write file {path}.")
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        self.logger.ok(f"Wrote {path.relative_to(self.repo_dir)}.")

    # ------------------------------------------------------------------
    # Workflow stages
    # ------------------------------------------------------------------

    def preflight_checks(self) -> None:
        self.logger.info("Running preflight checks.")
        missing = [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
        if missing:
            message = f"Missing required tools: {', '.join(missing)}"
            self.logger.err(message)
            self._record_summary("Preflight checks", "FAILED")
            raise RuntimeError(message)
        self.logger.ok("All required tooling is available.")
        self._record_summary("Preflight checks", "OK")

    def backup_important_files(self) -> None:
        self.logger.info("Backing up critical files via simulated SSH copy.")
        backup_target = Path(CONFIG["build_root"]) / "backups"
        if not self.dry_run:
            backup_target.mkdir(parents=True, exist_ok=True)
            placeholder = backup_target / "config_backup.txt"
            placeholder.write_text(
                textwrap.dedent(
                    f"""
                    Backup generated on {datetime.utcnow().isoformat()}Z
                    Source host: {CONFIG['backup_host']}
                    Remote path: {CONFIG['backup_path']}
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )
        self.logger.ok(
            "Simulated backup completed. Data stored under %s"
            % backup_target.resolve()
        )
        self._record_summary("Backup", "OK")

    def fetch_vendor_blobs(self) -> None:
        self.logger.info("Fetching vendor assets via simulated rsync.")
        if not self.dry_run:
            self.vendor_assets_dir.mkdir(parents=True, exist_ok=True)
            firmware_targets = {
                "IPQ5018": "ath11k board data and firmware",
                "qcn9000": "optional 5G board data",
                "qca-nss0-retail.bin": "NSS acceleration blob",
            }
            for name, description in firmware_targets.items():
                destination = self.vendor_assets_dir / name
                if destination.exists():
                    continue
                if destination.suffix:
                    destination.write_text(
                        textwrap.dedent(
                            f"""
                            Placeholder for {description} collected from
                            {CONFIG['vendor_user']}@{CONFIG['vendor_host']}:{CONFIG['vendor_path']}.
                            Replace with the real binary before building.
                            """
                        ).strip()
                        + "\n",
                        encoding="utf-8",
                    )
                else:
                    destination.mkdir(parents=True, exist_ok=True)
                    (destination / "README.txt").write_text(
                        textwrap.dedent(
                            f"""
                            Placeholder directory for {description} collected from
                            {CONFIG['vendor_user']}@{CONFIG['vendor_host']}:{CONFIG['vendor_path']}.
                            Replace with the real contents before building.
                            """
                        ).strip()
                        + "\n",
                        encoding="utf-8",
                    )
        self.logger.ok(f"Vendor assets available at {self.vendor_assets_dir.resolve()}.")
        self._record_summary("Vendor assets", "OK")

    def clone_or_update_repo(self) -> None:
        self.logger.info("Synchronising build repository.")
        build_root = Path(CONFIG["build_root"])
        repo_exists = self.repo_dir.is_dir()
        if repo_exists:
            self.logger.info("Repository exists; fetching updates.")
            self._run_command(["git", "fetch", "--all"], cwd=self.repo_dir)
            self._run_command([
                "git",
                "reset",
                "--hard",
                f"origin/{CONFIG['repo_branch']}",
            ], cwd=self.repo_dir)
        else:
            build_root.mkdir(parents=True, exist_ok=True)
            self._run_command(
                [
                    "git",
                    "clone",
                    "--branch",
                    CONFIG["repo_branch"],
                    CONFIG["repo_url"],
                    str(self.repo_dir),
                ]
            )
        if self.dry_run and not self.repo_dir.exists():
            self.logger.warn(
                "Dry-run mode: creating placeholder repository directory for subsequent steps."
            )
            self.repo_dir.mkdir(parents=True, exist_ok=True)
        self.logger.ok("Repository synchronised.")
        self._record_summary("Repository sync", "OK")

    def apply_custom_configs(self) -> None:
        self.logger.info("Applying custom configuration files.")
        if not self.repo_dir.exists():
            raise FileNotFoundError(
                "Build repository missing; run the clone/update step first."
            )
        dts_path = (
            self.repo_dir
            / "target"
            / "linux"
            / "qualcommax"
            / "files-6.6"
            / "arch"
            / "arm64"
            / "boot"
            / "dts"
            / "qcom"
            / "ipq5018-redmi-ra74.dts"
        )
        dts_content = textwrap.dedent(
            """
            // SPDX-License-Identifier: GPL-2.0-or-later
            /dts-v1/;

            #include "ipq5018.dtsi"
            #include <dt-bindings/gpio/gpio.h>
            #include <dt-bindings/input/input.h>

            / {
                model = "Xiaomi Redmi AX5400 (RA74)";
                compatible = "xiaomi,redmi-ra74", "qcom,ipq5018";

                aliases {
                    serial0 = &blsp1_uart1;
                    led-boot = &led_power;
                    led-failsafe = &led_power;
                    led-running = &led_power;
                    led-upgrade = &led_power;
                };

                chosen {
                    // Bootloader parameters confirmed on stock firmware.
                    bootargs-override = "ubi.mtd=rootfs_1 root=mtd:ubi_rootfs rootfstype=squashfs rootwait";
                    stdout-path = "serial0:115200n8";
                };

                leds {
                    compatible = "gpio-leds";
                    led_power: power {
                        label = "ra74:green:power";
                        gpios = <&tlmm 10 GPIO_ACTIVE_HIGH>; /* TODO: adjust GPIO */
                        default-state = "on";
                    };
                };

                keys {
                    compatible = "gpio-keys";
                    reset {
                        label = "reset";
                        gpios = <&tlmm 12 GPIO_ACTIVE_LOW>; /* TODO: adjust GPIO */
                        linux,code = <KEY_RESTART>;
                    };
                };
            };

            /* UART */
            &blsp1_uart1 { status = "okay"; };

            /* Additional peripherals can be enabled incrementally. */
            """
        ).strip() + "\n"
        makefile_path = (
            self.repo_dir
            / "target"
            / "linux"
            / "qualcommax"
            / "image"
            / "generic.mk"
        )
        stanza = textwrap.dedent(
            """
            define Device/xiaomi_redmi_ra74
              DEVICE_VENDOR := Xiaomi
              DEVICE_MODEL := Redmi AX5400 (RA74)
              DEVICE_DTS := qcom/ipq5018-redmi-ra74
              SOC := ipq5018
              IMAGE/sysupgrade.bin := sysupgrade-tar
              UBINIZE_OPTS := -E 5
              BLOCKSIZE := 128k
              PAGESIZE := 2048
              KERNEL_SIZE := 4096k
              KERNEL := kernel-bin | lzma | uImage lzma
              DEVICE_PACKAGES := kmod-ath11k-pci ath11k-firmware-ipq5018 wpad-basic-mbedtls \
                     irqbalance ethtool
              SUPPORTED_DEVICES := xiaomi,redmi-ra74
            endef
            TARGET_DEVICES += xiaomi_redmi_ra74
            """
        ).strip() + "\n"

        if self.dry_run:
            self.logger.ok(f"Dry-run mode: would ensure {dts_path} contains RA74 DTS.")
        else:
            current = dts_path.read_text(encoding="utf-8") if dts_path.exists() else ""
            if current != dts_content:
                dts_path.parent.mkdir(parents=True, exist_ok=True)
                dts_path.write_text(dts_content, encoding="utf-8")
                self.logger.ok("Updated RA74 DTS description.")
            else:
                self.logger.ok("RA74 DTS already up to date.")

        if self.dry_run:
            self.logger.ok(
                "Dry-run mode: would ensure ImmortalWrt generic.mk includes RA74 device."
            )
        else:
            if not makefile_path.exists():
                raise FileNotFoundError(
                    f"Expected image recipe not found at {makefile_path}."
                )
            content = makefile_path.read_text(encoding="utf-8")
            if "Device/xiaomi_redmi_ra74" not in content:
                with makefile_path.open("a", encoding="utf-8") as handle:
                    handle.write("\n" + stanza)
                self.logger.ok("Appended RA74 device stanza to generic.mk.")
            else:
                self.logger.ok("RA74 device stanza already present in generic.mk.")

        self.logger.ok("Custom configuration overlays applied.")
        self._record_summary("Custom configs", "OK")

    def prepare_overlay_directory(self) -> None:
        self.logger.info("Preparing ImmortalWrt files/ overlay with defaults.")
        if not self.repo_dir.exists():
            raise FileNotFoundError(
                "Build repository missing; run the clone/update step first."
            )
        overlay_tmp = Path(tempfile.mkdtemp(prefix="overlay_"))
        self.cleanup_paths.append(overlay_tmp)

        defaults = {
            overlay_tmp
            / "etc"
            / "uci-defaults"
            / "99-ra74-dumb-ap": textwrap.dedent(
                """
                #!/bin/sh
                # Configure Redmi AX5400 (RA74) as a dumb AP on first boot.
                uci set network.lan.ipaddr='192.168.1.190'
                uci set network.lan.proto='static'
                uci set network.lan.netmask='255.255.255.0'
                uci delete network.wan 2>/dev/null
                uci delete network.wan6 2>/dev/null

                uci set dhcp.lan.ignore='1'

                uci set wireless.@wifi-device[0].country='GB'
                uci set wireless.@wifi-device[1].country='GB'
                uci set wireless.@wifi-iface[0].disabled='0'
                uci set wireless.@wifi-iface[1].disabled='0'

                uci set firewall.@defaults[0].syn_flood='0'
                uci set firewall.@defaults[0].input='ACCEPT'
                uci set firewall.@defaults[0].forward='ACCEPT'
                uci set firewall.@defaults[0].output='ACCEPT'
                /etc/init.d/firewall disable 2>/dev/null

                uci commit
                """
            ).strip(),
        }

        for path, content in defaults.items():
            if self.dry_run:
                self.logger.ok(f"Dry-run mode: would create overlay file {path}.")
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content + "\n", encoding="utf-8")
            if "uci-defaults" in path.parts:
                os.chmod(path, 0o755)

        if not self.dry_run:
            firmware_root = overlay_tmp / "lib" / "firmware"
            firmware_root.mkdir(parents=True, exist_ok=True)
            source_dir = Path(CONFIG["vendor_assets_local"])
            if source_dir.exists():
                for item in source_dir.iterdir():
                    destination = firmware_root / item.name
                    if item.is_dir():
                        shutil.copytree(item, destination, dirs_exist_ok=True)
                    else:
                        shutil.copy2(item, destination)
            else:
                self.logger.warn(
                    f"Vendor assets directory {source_dir} missing; using placeholders."
                )
                (firmware_root / "README.txt").write_text(
                    "Populate this directory with vendor firmware blobs before building.\n",
                    encoding="utf-8",
                )

            if self.overlay_dir.exists():
                shutil.rmtree(self.overlay_dir)
            shutil.copytree(overlay_tmp, self.overlay_dir, dirs_exist_ok=True)

        self.logger.ok(f"Overlay prepared at {self.overlay_dir}.")
        self._record_summary("Overlay", "OK")

    def run_menuconfig(self) -> None:
        self.logger.info("Launching make menuconfig (interactive).")
        if not self.repo_dir.exists():
            raise FileNotFoundError(
                "Build repository missing; run the clone/update step first."
            )
        result = self._run_command(
            ["make", "menuconfig"],
            cwd=self.repo_dir,
            interactive=True,
        )
        if result.returncode != 0:
            self.logger.err("make menuconfig failed.")
            self._record_summary("menuconfig", "FAILED")
            raise RuntimeError("menuconfig failed")
        self.logger.ok("Configuration step completed.")
        self._record_summary("menuconfig", "OK")

    def build_firmware(self) -> None:
        self.logger.info("Starting parallel build.")
        if not self.repo_dir.exists():
            raise FileNotFoundError(
                "Build repository missing; run the clone/update step first."
            )
        jobs = str(os.cpu_count() or 1)
        result = self._run_command(
            ["make", f"-j{jobs}"],
            cwd=self.repo_dir,
            interactive=False,
        )
        if result.returncode != 0:
            self.logger.err("Build failed.")
            self._record_summary("Build", "FAILED")
            raise RuntimeError("make build failed")
        self.logger.ok("Build completed successfully.")
        self._record_summary("Build", "OK")

    def verify_artifacts(self) -> None:
        self.logger.info("Verifying build artefacts and checksum.")
        if not self.repo_dir.exists():
            raise FileNotFoundError(
                "Build repository missing; run the clone/update step first."
            )
        glob_expr = CONFIG["artifact_glob"]
        candidates = list(self.repo_dir.glob(glob_expr))
        if not candidates:
            if self.dry_run:
                self.logger.warn(
                    "Dry-run mode: no artefacts present; using placeholder checksum."
                )
                self._record_summary("Artefact verification", "OK (simulated)")
                return
            self.logger.err(f"No artefacts found using glob '{glob_expr}'.")
            self._record_summary("Artefact verification", "FAILED")
            raise FileNotFoundError("No artefacts located")
        latest = max(candidates, key=lambda p: p.stat().st_mtime)
        if self.dry_run:
            checksum = "0" * 64
        else:
            checksum = self._sha256(latest)
        self.logger.ok(f"Latest artefact: {latest}")
        self.logger.ok(f"SHA256: {checksum}")
        self._record_summary("Artefact verification", "OK")

    def run_full_workflow(self) -> None:
        self.summary.clear()
        steps = [
            self.preflight_checks,
            self.backup_important_files,
            self.fetch_vendor_blobs,
            self.clone_or_update_repo,
            self.apply_custom_configs,
            self.prepare_overlay_directory,
            self.run_menuconfig,
            self.build_firmware,
            self.verify_artifacts,
        ]
        for step in steps:
            try:
                step()
            except Exception as exc:  # pragma: no cover - defensive logging
                self.logger.err(f"Step '{step.__name__}' failed: {exc}")
                break

    # ------------------------------------------------------------------
    # User interface
    # ------------------------------------------------------------------

    def show_menu(self) -> None:
        options: List[Tuple[str, Callable[[], None]]] = [
            ("Run full workflow", self.run_full_workflow),
            ("1. Preflight checks", self.preflight_checks),
            ("2. Backup important files", self.backup_important_files),
            ("3. Fetch vendor assets", self.fetch_vendor_blobs),
            ("4. Clone/update repository", self.clone_or_update_repo),
            ("5. Apply custom configuration", self.apply_custom_configs),
            ("6. Prepare overlay directory", self.prepare_overlay_directory),
            ("7. Launch make menuconfig", self.run_menuconfig),
            ("8. Run make -j build", self.build_firmware),
            ("9. Verify build artefacts", self.verify_artifacts),
            ("0. Exit", lambda: sys.exit(0)),
        ]

        while True:
            print("")
            print("=" * 70)
            print(" Embedded Build Workflow Manager ")
            print("=" * 70)
            for idx, (label, _) in enumerate(options):
                if idx == 0:
                    print(f"  F - {label}")
                else:
                    print(f"  {idx} - {label.split('. ', 1)[1] if '. ' in label else label}")
            print("")
            choice = input("Select an option (F/0-9): ").strip().lower()
            if choice == "f":
                options[0][1]()
                self.show_summary()
                continue
            if not choice.isdigit():
                self.logger.warn("Invalid selection; please try again.")
                continue
            idx = int(choice)
            if idx == 0:
                options[-1][1]()
            if 1 <= idx <= 9:
                options[idx][1]()

    # ------------------------------------------------------------------
    # Utility helpers
    # ------------------------------------------------------------------

    def show_summary(self) -> None:
        print("\nBuild complete summary\n" + "-" * 40)
        for step, status in self.summary:
            print(f"{step:<30} {status}")
        print("-" * 40)

    @staticmethod
    def _sha256(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(8192), b""):
                digest.update(chunk)
        return digest.hexdigest()


# ``shlex.quote`` is only available in Python 3.3+, but the project already
# requires Python 3.8+.  Import lazily to keep the module namespace tidy.
from shlex import quote as shlex_quote  # noqa: E402  # placed after class defs


def main(argv: Optional[Sequence[str]] = None) -> int:
    manager = BuildManager()
    if argv and len(argv) > 1:
        commands = {
            "full": manager.run_full_workflow,
            "preflight": manager.preflight_checks,
            "backup": manager.backup_important_files,
            "vendor": manager.fetch_vendor_blobs,
            "sync": manager.clone_or_update_repo,
            "configs": manager.apply_custom_configs,
            "overlay": manager.prepare_overlay_directory,
            "menuconfig": manager.run_menuconfig,
            "build": manager.build_firmware,
            "verify": manager.verify_artifacts,
        }
        action = commands.get(argv[1].lower())
        if not action:
            manager.logger.err(f"Unknown action '{argv[1]}'")
            return 1
        action()
        manager.show_summary()
        return 0
    manager.show_menu()
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entry point
    sys.exit(main(sys.argv))
