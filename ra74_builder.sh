#!/usr/bin/env bash
# Redmi AX5400 (RA74) ImmortalWrt Builder & Flasher
# - Backs up critical partitions
# - Pulls vendor firmware blobs
# - Prepares ImmortalWrt tree with RA74 device
# - Builds UBI+squashfs sysupgrade image
# - Optionally flashes via sysupgrade
#
# USE AT YOUR OWN RISK. Have TFTP recovery and the stock image ready.

set -euo pipefail

########################################
# User-configurable defaults
########################################
ROUTER_IP="${ROUTER_IP:-192.168.1.190}"
ROUTER_USER="${ROUTER_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"
PC_WORKDIR="${PC_WORKDIR:-$HOME/ra74-work}"
BACKUP_DIR="${BACKUP_DIR:-$PC_WORKDIR/backups}"
FW_GRAB_DIR="${FW_GRAB_DIR:-$PC_WORKDIR/vendor-fw}"
BUILD_ROOT="${BUILD_ROOT:-$PC_WORKDIR/immortalwrt}"
GIT_URL="${GIT_URL:-https://github.com/immortalwrt/immortalwrt.git}"
DEVICE_DTS="ipq5018-redmi-ra74.dts"
QUAL_DIR_REL="target/linux/qualcommax"
DTS_DIR_REL="arch/arm64/boot/dts/qcom"
FILES_OVERLAY_DIR="${BUILD_ROOT}/files"
UCI_DEFAULTS_PATH="${FILES_OVERLAY_DIR}/etc/uci-defaults/99-ra74-dumb-ap"
LOG_FILE="${PC_WORKDIR}/ra74_builder.log"
DRY_RUN="${DRY_RUN:-0}"   # set to 1 for dry-run

########################################
# UI helpers
########################################
c_reset="\033[0m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_cyan="\033[36m"
say() { printf "${c_cyan}==>${c_reset} %s\n" "$*" | tee -a "$LOG_FILE"; }
ok()  { printf "${c_green}[OK]${c_reset} %s\n" "$*" | tee -a "$LOG_FILE"; }
warn(){ printf "${c_yellow}[!]${c_reset} %s\n" "$*" | tee -a "$LOG_FILE"; }
err() { printf "${c_red}[X]${c_reset} %s\n" "$*" | tee -a "$LOG_FILE"; }

confirm() {
  local prompt="${1:-Proceed?} [y/N]: "
  read -rp "$prompt" ans || true
  [[ "${ans:-}" =~ ^[Yy]$ ]]
}

run() {
  echo "\$ $*" >> "$LOG_FILE"
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "DRY-RUN: $*"
  else
    eval "$@" 2>&1 | tee -a "$LOG_FILE"
  fi
}

ssh_exec() {
  local cmd="$1"
  echo "ssh ${ROUTER_USER}@${ROUTER_IP} '$cmd'" >> "$LOG_FILE"
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "DRY-RUN SSH: $cmd"
  else
    ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "${ROUTER_USER}@${ROUTER_IP}" "$cmd"
  fi
}

scp_get() {
  local remote="$1" local_path="$2"
  echo "scp ${ROUTER_USER}@${ROUTER_IP}:$remote $local_path" >> "$LOG_FILE"
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "DRY-RUN SCP GET: $remote -> $local_path"
  else
    scp -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new "${ROUTER_USER}@${ROUTER_IP}:$remote" "$local_path"
  fi
}

scp_put() {
  local local_path="$1" remote="$2"
  echo "scp $local_path ${ROUTER_USER}@${ROUTER_IP}:$remote" >> "$LOG_FILE"
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "DRY-RUN SCP PUT: $local_path -> $remote"
  else
    scp -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new "$local_path" "${ROUTER_USER}@${ROUTER_IP}:$remote"
  fi
}

########################################
# Preflight checks
########################################
require_cmds() {
  local missing=()
  for c in ssh scp git make awk sed grep cut tar dd sha256sum; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    err "Missing commands: ${missing[*]}"
    exit 1
  fi
  ok "All required commands present."
}

ensure_dirs() {
  mkdir -p "$PC_WORKDIR" "$BACKUP_DIR" "$FW_GRAB_DIR" "$BUILD_ROOT" "$(dirname "$LOG_FILE")"
  ok "Directories ready under $PC_WORKDIR"
}

ping_router() {
  say "Checking router reachability at ${ROUTER_IP}..."
  if ping -c1 -W1 "$ROUTER_IP" >/dev/null 2>&1; then ok "Router reachable."
  else err "Router not reachable. Check network."; exit 1; fi
}

ssh_sanity() {
  say "Verifying SSH connectivity..."
  if ssh_exec "echo Connected && uname -a && cat /proc/cmdline"; then ok "SSH working."
  else err "SSH failed. Ensure credentials & IP are correct."; exit 1; fi
}

########################################
# 1) Backups
########################################
backups() {
  say "Creating partition & config backups to $BACKUP_DIR"
  ssh_exec "cat /proc/mtd" > "${BACKUP_DIR}/proc-mtd.txt"
  ssh_exec "dmesg" > "${BACKUP_DIR}/dmesg.txt"
  ssh_exec "cat /proc/cmdline" > "${BACKUP_DIR}/cmdline.txt"

  # Parse names to ensure indexes match (from your posted layout)
  local mtd_kernel=22 mtd_ubi_rootfs=23 mtd_overlay=20 mtd_data=24 mtd_art=13

  say "Backing up mtd${mtd_kernel} kernel..."
  ssh_exec "dd if=/dev/mtd${mtd_kernel} bs=1M" > "${BACKUP_DIR}/mtd${mtd_kernel}-kernel.bin"
  say "Backing up mtd${mtd_ubi_rootfs} ubi_rootfs..."
  ssh_exec "dd if=/dev/mtd${mtd_ubi_rootfs} bs=1M" > "${BACKUP_DIR}/mtd${mtd_ubi_rootfs}-ubi_rootfs.bin"
  say "Backing up mtd${mtd_overlay} overlay..."
  ssh_exec "dd if=/dev/mtd${mtd_overlay} bs=1M" > "${BACKUP_DIR}/mtd${mtd_overlay}-overlay.bin"
  say "Backing up mtd${mtd_data} data..."
  ssh_exec "dd if=/dev/mtd${mtd_data} bs=1M" > "${BACKUP_DIR}/mtd${mtd_data}-data.bin"
  say "Backing up mtd${mtd_art} ART (radio cal) ..."
  ssh_exec "dd if=/dev/mtd${mtd_art} bs=1M" > "${BACKUP_DIR}/mtd${mtd_art}-ART.bin"

  (cd "$BACKUP_DIR" && sha256sum * > checksums.sha256)
  ok "Backups completed at $BACKUP_DIR"
}

########################################
# 2) Grab vendor firmware blobs
########################################
grab_vendor_blobs() {
  say "Pulling vendor firmware blobs into $FW_GRAB_DIR"
  run "mkdir -p '$FW_GRAB_DIR'"
  # Copy directories if they exist
  if ssh_exec "test -d /lib/firmware/IPQ5018"; then
    run "rsync -avz -e 'ssh -p $SSH_PORT -o StrictHostKeyChecking=accept-new' ${ROUTER_USER}@${ROUTER_IP}:/lib/firmware/IPQ5018/ '$FW_GRAB_DIR/IPQ5018/'"
  else warn "/lib/firmware/IPQ5018 not found on router (unexpected)."; fi

  if ssh_exec "test -d /lib/firmware/qcn9000"; then
    run "rsync -avz -e 'ssh -p $SSH_PORT -o StrictHostKeyChecking=accept-new' ${ROUTER_USER}@${ROUTER_IP}:/lib/firmware/qcn9000/ '$FW_GRAB_DIR/qcn9000/'"
  else warn "/lib/firmware/qcn9000 not present (may be fine)."; fi

  if ssh_exec "test -f /lib/firmware/qca-nss0-retail.bin"; then
    scp_get "/lib/firmware/qca-nss0-retail.bin" "$FW_GRAB_DIR/"
  else warn "qca-nss0-retail.bin not present (ok if not using NSS now)."; fi

  ok "Vendor blobs fetched."
}

########################################
# 3) Clone/update ImmortalWrt
########################################
setup_immortalwrt() {
  if [[ -d "$BUILD_ROOT/.git" ]]; then
    say "Updating existing ImmortalWrt at $BUILD_ROOT"
    (cd "$BUILD_ROOT" && run "git fetch --all --tags" && run "git pull")
  else
    say "Cloning ImmortalWrt into $BUILD_ROOT"
    run "git clone '$GIT_URL' '$BUILD_ROOT'"
  fi
  (cd "$BUILD_ROOT" && run "./scripts/feeds update -a" && run "./scripts/feeds install -a")
  ok "ImmortalWrt tree ready."
}

########################################
# 4) Write DTS + Image recipe + Files overlay
########################################
detect_files_dir() {
  # ImmortalWrt currently uses kernel 6.6 in qualcommax; detect files-* dir
  local base="$BUILD_ROOT/$QUAL_DIR_REL"
  local files_dir
  files_dir="$(find "$base" -maxdepth 1 -type d -name 'files-*' | sort -r | head -n1 || true)"
  if [[ -z "$files_dir" ]]; then
    err "Cannot find $QUAL_DIR_REL/files-*/ in tree. Tree layout changed?"
    exit 1
  fi
  echo "$files_dir"
}

write_dts() {
  local files_dir dts_dir
  files_dir="$(detect_files_dir)"
  dts_dir="$files_dir/$DTS_DIR_REL"
  run "mkdir -p '$dts_dir'"

  say "Writing DTS to $dts_dir/${DEVICE_DTS}"
  cat > "$dts_dir/${DEVICE_DTS}" <<'EOF'
/*
 * Xiaomi Redmi AX5400 (RA74) - minimal DTS skeleton for ImmortalWrt
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
 /dts-v1/;

#include "ipq5018.dtsi"

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
        bootargs-override = "ubi.mtd=rootfs_1 root=mtd:ubi_rootfs rootfstype=squashfs rootwait";
        stdout-path = "serial0:115200n8";
    };

    leds {
        compatible = "gpio-leds";
        led_power: power {
            label = "ra74:green:power";
            gpios = <&tlmm 10 GPIO_ACTIVE_HIGH>; /* TODO: adjust GPIO if needed */
            default-state = "on";
        };
    };

    keys {
        compatible = "gpio-keys";
        reset {
            label = "reset";
            gpios = <&tlmm 12 GPIO_ACTIVE_LOW>; /* TODO: adjust GPIO if needed */
            linux,code = <KEY_RESTART>;
        };
    };
};

&blsp1_uart1 { status = "okay"; };

/* Keep stock bootloader + stock UBI layout.
 * Wi-Fi firmware/board files will be placed under /lib/firmware/IPQ5018 via files/ overlay.
 */
EOF
  ok "DTS written."
}

write_image_recipe() {
  local mk="${BUILD_ROOT}/${QUAL_DIR_REL}/image/generic.mk"
  say "Injecting RA74 device into ${mk} (idempotent)."
  if ! grep -q "Device/xiaomi_redmi_ra74" "$mk"; then
    cat >> "$mk" <<'EOF'

#### Xiaomi Redmi AX5400 (RA74) - IPQ5018 SPI-NAND UBI
define Device/xiaomi_redmi_ra74
  DEVICE_VENDOR := Xiaomi
  DEVICE_MODEL := Redmi AX5400 (RA74)
  DEVICE_DTS := qcom/ipq5018-redmi-ra74
  SOC := ipq5018
  # Ensure UBI + squashfs rootfs. Helpers may differ across revisions.
  IMAGE/sysupgrade.bin := sysupgrade-tar
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_SIZE := 4096k
  KERNEL := kernel-bin | lzma | uImage lzma
  DEVICE_PACKAGES := kmod-ath11k-pci ath11k-firmware-ipq5018 wpad-basic-mbedtls irqbalance ethtool
  SUPPORTED_DEVICES := xiaomi,redmi-ra74
endef
TARGET_DEVICES += xiaomi_redmi_ra74

EOF
    ok "Image recipe appended."
  else
    ok "Image recipe already present."
  fi
}

write_files_overlay() {
  say "Preparing files/ overlay for vendor blobs and first-boot AP config."
  run "mkdir -p '${FILES_OVERLAY_DIR}/lib/firmware' '${FILES_OVERLAY_DIR}/etc/uci-defaults'"

  if [[ -d "$FW_GRAB_DIR/IPQ5018" ]]; then
    run "cp -a '$FW_GRAB_DIR/IPQ5018' '${FILES_OVERLAY_DIR}/lib/firmware/'"
  else
    warn "No IPQ5018 vendor folder found in $FW_GRAB_DIR. Wi-Fi may need manual blobs."
  fi

  if [[ -d "$FW_GRAB_DIR/qcn9000" ]]; then
    run "cp -a '$FW_GRAB_DIR/qcn9000' '${FILES_OVERLAY_DIR}/lib/firmware/'"
  fi

  if [[ -f "$FW_GRAB_DIR/qca-nss0-retail.bin" ]]; then
    run "cp -a '$FW_GRAB_DIR/qca-nss0-retail.bin' '${FILES_OVERLAY_DIR}/lib/firmware/'"
  fi

  cat > "$UCI_DEFAULTS_PATH" <<'EOF'
#!/bin/sh
# First boot: configure as Dumb AP on 192.168.1.190

set -e

uci -q set network.lan.proto='static'
uci -q set network.lan.ipaddr='192.168.1.190'
uci -q set network.lan.netmask='255.255.255.0'
uci -q delete network.wan 2>/dev/null || true
uci -q delete network.wan6 2>/dev/null || true

# Disable DHCP server
uci -q set dhcp.lan.ignore='1'

# Enable Wi-Fi (country can be changed later)
uci -q set wireless.@wifi-device[0].country='GB'
uci -q set wireless.@wifi-iface[0].disabled='0'
# if second radio exists:
[ -n "$(uci -q show wireless.@wifi-device[1] 2>/dev/null)" ] && uci -q set wireless.@wifi-device[1].country='GB'
[ -n "$(uci -q show wireless.@wifi-iface[1] 2>/dev/null)" ] && uci -q set wireless.@wifi-iface[1].disabled='0'

# Loosen firewall / disable for pure AP
if uci -q show firewall >/dev/null 2>&1; then
  uci -q set firewall.@defaults[0].syn_flood='0'
  uci -q set firewall.@defaults[0].input='ACCEPT'
  uci -q set firewall.@defaults[0].forward='ACCEPT'
  uci -q set firewall.@defaults[0].output='ACCEPT'
fi
/etc/init.d/firewall disable 2>/dev/null || true

uci -q commit
EOF
  run "chmod +x '$UCI_DEFAULTS_PATH'"
  ok "Overlay + uci-defaults prepared."
}

########################################
# 5) Configure & Build
########################################
menuconfig_hint() {
  say "Opening menuconfig (Target: Qualcomm Atheros IPQ (qualcommax) / ipq50xx → select Xiaomi Redmi AX5400 (RA74))."
  say "Ensure kmod-ath11k-pci + ath11k-firmware-ipq5018 are enabled."
  if confirm "Launch make menuconfig now?"; then
    (cd "$BUILD_ROOT" && run "make menuconfig")
  else
    warn "Skipping menuconfig; be sure .config is correct."
  fi
}

build_firmware() {
  say "Starting build (this can take a while)..."
  (cd "$BUILD_ROOT" && run "make -j\$(nproc)")
  ok "Build finished (check bin/targets/qualcommax/ipq50xx/)"
}

find_sysupgrade() {
  local out_dir="$BUILD_ROOT/bin/targets/qualcommax/ipq50xx"
  if [[ -d "$out_dir" ]]; then
    sysimg="$(ls -1 "$out_dir"/*ra74*sysupgrade*.bin 2>/dev/null | head -n1 || true)"
    if [[ -n "${sysimg:-}" && -f "$sysimg" ]]; then
      echo "$sysimg"; return 0
    fi
  fi
  return 1
}

########################################
# 6) Flash (optional)
########################################
flash_sysupgrade() {
  local img="$1"
  say "Verifying image checksum:"
  run "sha256sum '$img'"

  if ! confirm "Proceed to upload to router /tmp and flash with sysupgrade -n?"; then
    warn "Flash aborted by user."; return 0
  fi

  scp_put "$img" "/tmp/"
  local base; base="$(basename "$img")"

  say "Attempting sysupgrade..."
  ssh_exec "cd /tmp && sha256sum '$base' && (command -v sysupgrade >/dev/null 2>&1 || echo 'sysupgrade not found') && sysupgrade -n '/tmp/$base' || echo 'sysupgrade command failed or not present.'"

  ok "If sysupgrade ran, device will reboot. If not, use xmir-patcher's installer route."
}

########################################
# 7) TFTP / Rollback guidance
########################################
rollback_instructions() {
  cat <<'EOT'

================ ROLLBACK / TFTP RECOVERY ================
1) Keep a copy of stock RA74 1.0.63 firmware with checksum.
2) Set your PC to a static IP (e.g., 192.168.1.10/24) and run a TFTP server.
3) Power off router. Hold RESET while powering on to enter recovery.
4) The bootloader may fetch a specific filename via TFTP (check logs). Serve the stock image with that name.
5) If TFTP recovery doesn't trigger, you may need serial (UART) access.

Your backups are under: BACKUP_DIR
EOT
}

########################################
# Menu
########################################
menu() {
  clear
  cat <<EOF
==========================================
 Redmi AX5400 (RA74) ImmortalWrt Builder
 Workdir: $PC_WORKDIR
 Router : $ROUTER_USER@$ROUTER_IP (port $SSH_PORT)
 Log    : $LOG_FILE
==========================================
 1) Preflight checks (required)
 2) Backups (mtd partitions, dmesg, cmdline)
 3) Grab vendor firmware blobs
 4) Clone/Update ImmortalWrt
 5) Write RA74 DTS & Image recipe
 6) Prepare files/ overlay (blobs + Dumb AP uci-defaults)
 7) make menuconfig
 8) Build firmware
 9) Flash sysupgrade image to router
10) Show rollback/TFTP guidance
11) Toggle DRY-RUN (current: $DRY_RUN)
 0) Exit
EOF
  read -rp "Choose: " choice || true
  case "${choice:-}" in
    1) require_cmds; ensure_dirs; ping_router; ssh_sanity; read -rp "Enter to continue..." _ ;;
    2) backups; read -rp "Enter to continue..." _ ;;
    3) grab_vendor_blobs; read -rp "Enter to continue..." _ ;;
    4) setup_immortalwrt; read -rp "Enter to continue..." _ ;;
    5) write_dts; write_image_recipe; read -rp "Enter to continue..." _ ;;
    6) write_files_overlay; read -rp "Enter to continue..." _ ;;
    7) menuconfig_hint; read -rp "Enter to continue..." _ ;;
    8) build_firmware; read -rp "Enter to continue..." _ ;;
    9) img="$(find_sysupgrade || true)"; if [[ -n "${img:-}" ]]; then
         say "Found image: $img"; flash_sysupgrade "$img";
       else err "No sysupgrade image found. Build first."; fi
       read -rp "Enter to continue..." _ ;;
    10) rollback_instructions; read -rp "Enter to continue..." _ ;;
    11) if [[ "$DRY_RUN" == "1" ]]; then DRY_RUN=0; ok "DRY-RUN disabled."; else DRY_RUN=1; warn "DRY-RUN enabled."; fi; sleep 1 ;;
    0) exit 0 ;;
    *) warn "Invalid choice." ;;
  esac
}

########################################
# Main
########################################
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
say "Log started at $(date -Is)"

while true; do
  menu
done

