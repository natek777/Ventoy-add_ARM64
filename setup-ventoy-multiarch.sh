#!/usr/bin/env bash
# ==============================================================================
# setup-ventoy-multiarch.sh
# Cross-platform (Linux & macOS) automation script to configure an existing
# Ventoy USB drive and portable folder for dual-architecture (x86_64 + ARM64)
# booting, organize/download ISOs directly to the USB drive, patch the hidden
# VTOYEFI partition with startup.nsh, and create QEMU boot test scripts.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENTOY_PATH="$(dirname "$SCRIPT_DIR")"
USB_MOUNT=""
USB_DEV=""
UBUNTU_LTS="26.04"
DOWNLOAD_ISOS=0
SETUP_QEMU=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -p, --ventoy-path PATH   Path to Ventoy installation/portable folder (default: $VENTOY_PATH)
  -m, --mount PATH         Mount point of the Ventoy data partition (auto-detected if omitted)
  -d, --device DEV         Block device of the Ventoy USB drive, e.g. /dev/sdb or /dev/disk2 (auto-detected)
  -u, --ubuntu-version VER Ubuntu LTS version to download (default: $UBUNTU_LTS)
      --download-isos      Download Ubuntu LTS (x86_64/ARM64), Win11 ARM64, Debian & Alpine ARM64 ISOs
      --setup-qemu         Create Linux/macOS QEMU test scripts (x86_64 UEFI, ARM64 UEFI, x86 BIOS)
  -h, --help               Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--ventoy-path) VENTOY_PATH="$2"; shift 2 ;;
        -m|--mount)       USB_MOUNT="$2"; shift 2 ;;
        -d|--device)      USB_DEV="$2"; shift 2 ;;
        -u|--ubuntu-version) UBUNTU_LTS="$2"; shift 2 ;;
        --download-isos)  DOWNLOAD_ISOS=1; shift ;;
        --setup-qemu)     SETUP_QEMU=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "Unknown parameter: $1"; usage; exit 1 ;;
    esac
done

OS_TYPE="$(uname -s)"
echo "=================================================================="
echo "  Ventoy Multi-Architecture (x86_64 + ARM64) Setup ($OS_TYPE)"
echo "=================================================================="

# 1. Validate Ventoy Portable Folder
if [[ ! -d "$VENTOY_PATH" ]]; then
    read -r -p "Enter path to your Ventoy portable folder: " VENTOY_PATH
fi
VENTOY_PATH="$(cd "$VENTOY_PATH" && pwd)"
echo "[+] Using Ventoy Portable Folder: $VENTOY_PATH"

# 2. Auto-detect Ventoy Data Mount & Block Device on Linux / macOS
if [[ -z "$USB_MOUNT" ]]; then
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        if [[ -d "/Volumes/Ventoy" ]]; then
            USB_MOUNT="/Volumes/Ventoy"
        fi
    elif [[ "$OS_TYPE" == "Linux" ]]; then
        USB_MOUNT="$(lsblk -o LABEL,MOUNTPOINT -nr 2>/dev/null | awk '$1 == "Ventoy" && $2 != "" {print $2; exit}' || true)"
        if [[ -z "$USB_MOUNT" ]]; then
            for candidate in "/run/media/$USER/Ventoy" "/media/$USER/Ventoy" "/mnt/Ventoy"; do
                if [[ -d "$candidate" ]]; then USB_MOUNT="$candidate"; break; fi
            done
        fi
    fi
    if [[ -z "$USB_MOUNT" ]]; then
        read -r -p "Enter mount point of your Ventoy USB data partition (e.g. /Volumes/Ventoy or /media/$USER/Ventoy): " USB_MOUNT
    fi
fi

if [[ ! -d "$USB_MOUNT" ]]; then
    echo "[-] Error: Mount point '$USB_MOUNT' does not exist." >&2
    exit 1
fi

if [[ -z "$USB_DEV" ]]; then
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        PART_DEV="$(df "$USB_MOUNT" | tail -1 | awk '{print $1}')"
        USB_DEV="$(echo "$PART_DEV" | sed -E 's/s[0-9]+$//')"
    elif [[ "$OS_TYPE" == "Linux" ]]; then
        PART_DEV="$(df --output=source "$USB_MOUNT" | tail -1)"
        PKNAME="$(lsblk -no PKNAME "$PART_DEV" 2>/dev/null | head -1 || true)"
        if [[ -n "$PKNAME" ]]; then
            USB_DEV="/dev/$PKNAME"
        else
            USB_DEV="$(echo "$PART_DEV" | sed -E 's/[0-9]+$//')"
        fi
    fi
fi

echo "[+] Target Ventoy Mount:  $USB_MOUNT"
echo "[+] Target Ventoy Device: ${USB_DEV:-Unknown}"

# 3. Copy Native ARM / ARM64 / X64 Executables if present
if [[ -d "$VENTOY_PATH/altexe" ]]; then
    echo "[*] Copying native X64 / ARM / ARM64 executables from altexe/ to $VENTOY_PATH..."
    cp -f "$VENTOY_PATH/altexe/"*.exe "$VENTOY_PATH/" 2>/dev/null || true
fi

# 4. Create Directory Structure & Copy Portable Ventoy Suite + Theme
ISO_ROOT="$USB_MOUNT/iso"
ISO_X64="$ISO_ROOT/x86_64"
ISO_ARM64="$ISO_ROOT/arm64"
VENTOY_DIR="$USB_MOUNT/ventoy"
TOOLS_DIR="$USB_MOUNT/Tools"
TOOLS_VTOY="$TOOLS_DIR/Ventoy"
TOOLS_TEMP="$TOOLS_DIR/Temp"

mkdir -p "$ISO_X64" "$ISO_ARM64" "$VENTOY_DIR" "$TOOLS_VTOY" "$TOOLS_TEMP"

echo "[*] Syncing portable Ventoy suite to $TOOLS_VTOY..."
for item in "$VENTOY_PATH"/*; do
    base="$(basename "$item")"
    if [[ "$base" != "add-arm46-ventoy" && "$base" != "add-arm64-ventoy" && "$base" != RMPrepUSB* ]]; then
        cp -Rf "$item" "$TOOLS_VTOY/" 2>/dev/null || true
    fi
done

if [[ -d "$VENTOY_PATH/plugin/ventoy/theme" ]]; then
    echo "[*] Installing Ventoy GUI theme to $VENTOY_DIR/theme..."
    mkdir -p "$VENTOY_DIR/theme"
    cp -Rf "$VENTOY_PATH/plugin/ventoy/theme/"* "$VENTOY_DIR/theme/"
fi

# 5. Organize Existing ISOs in <USB>/iso into x86_64 and arm64 Subfolders
echo "[*] Organizing existing ISOs in $ISO_ROOT into x86_64 and arm64 folders..."
shopt -s nullglob nocaseglob
for iso in "$ISO_ROOT"/*.iso; do
    fname="$(basename "$iso")"
    if [[ "$fname" =~ (arm64|aarch64) ]]; then
        echo "    -> Moving $fname to iso/arm64/"
        mv -f "$iso" "$ISO_ARM64/"
    else
        echo "    -> Moving $fname to iso/x86_64/"
        mv -f "$iso" "$ISO_X64/"
    fi
done
shopt -u nocaseglob

# 6. Patch Hidden VTOYEFI Partition with startup.nsh for Strict ARM64 UEFI Booting
echo "[*] Checking hidden VTOYEFI partition for ARM64 startup.nsh fallback..."
patch_vtoyefi() {
    local vtoy_mp=""
    local temp_mp=""
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        if [[ -d "/Volumes/VTOYEFI" ]]; then
            vtoy_mp="/Volumes/VTOYEFI"
        elif [[ -n "$USB_DEV" ]]; then
            local efi_part="${USB_DEV}s2"
            if diskutil info "$efi_part" >/dev/null 2>&1; then
                diskutil mount "$efi_part" >/dev/null 2>&1 || true
                [[ -d "/Volumes/VTOYEFI" ]] && vtoy_mp="/Volumes/VTOYEFI"
            fi
        fi
    elif [[ "$OS_TYPE" == "Linux" ]]; then
        vtoy_mp="$(lsblk -o LABEL,MOUNTPOINT -nr 2>/dev/null | awk '$1 == "VTOYEFI" && $2 != "" {print $2; exit}' || true)"
        if [[ -z "$vtoy_mp" ]]; then
            local efi_dev
            efi_dev="$(blkid -L "VTOYEFI" 2>/dev/null || true)"
            if [[ -n "$efi_dev" ]]; then
                temp_mp="$(mktemp -d /tmp/vtoyefi.XXXXXX)"
                if sudo mount "$efi_dev" "$temp_mp" 2>/dev/null; then
                    vtoy_mp="$temp_mp"
                else
                    rmdir "$temp_mp" 2>/dev/null || true
                    temp_mp=""
                fi
            fi
        fi
    fi

    if [[ -n "$vtoy_mp" && -d "$vtoy_mp" ]]; then
        if [[ -w "$vtoy_mp" ]]; then
            printf '\\EFI\\BOOT\\BOOTAA64.EFI\r\n' > "$vtoy_mp/startup.nsh"
        else
            printf '\\EFI\\BOOT\\BOOTAA64.EFI\r\n' | sudo tee "$vtoy_mp/startup.nsh" >/dev/null
        fi
        echo "[+] Wrote \\EFI\\BOOT\\BOOTAA64.EFI to $vtoy_mp/startup.nsh"
        if [[ -n "$temp_mp" ]]; then
            sudo umount "$temp_mp" 2>/dev/null || true
            rmdir "$temp_mp" 2>/dev/null || true
        fi
    else
        echo "[!] Warning: Could not auto-mount VTOYEFI partition to write startup.nsh."
    fi
}
patch_vtoyefi

# 7. Optional: Download Official ISOs Directly to <USB>/iso/
download_iso() {
    local url="$1"
    local dest="$2"
    local label="$3"
    if [[ -f "$dest" ]]; then
        local size
        if [[ "$OS_TYPE" == "Darwin" ]]; then
            size="$(stat -f%z "$dest" 2>/dev/null || echo 0)"
        else
            size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
        fi
        if (( size > 100000000 )); then
            echo "    [=] $label already exists. Skipping."
            return 0
        fi
    fi
    echo "    [v] Downloading $label -> $dest ..."
    curl -L "$url" -o "$dest"
}

if [[ "$DOWNLOAD_ISOS" -eq 1 ]]; then
    echo "[*] Downloading requested x86_64 & ARM64 ISOs directly to $ISO_ROOT..."
    download_iso "https://releases.ubuntu.com/${UBUNTU_LTS}/ubuntu-${UBUNTU_LTS}-desktop-amd64.iso" \
        "$ISO_X64/ubuntu-${UBUNTU_LTS}-desktop-amd64.iso" "Ubuntu ${UBUNTU_LTS} LTS Desktop (x86_64)"
    download_iso "https://releases.ubuntu.com/${UBUNTU_LTS}/ubuntu-${UBUNTU_LTS}-live-server-amd64.iso" \
        "$ISO_X64/ubuntu-${UBUNTU_LTS}-live-server-amd64.iso" "Ubuntu ${UBUNTU_LTS} LTS Live Server (x86_64)"
    download_iso "https://cdimage.ubuntu.com/releases/${UBUNTU_LTS}/release/ubuntu-${UBUNTU_LTS}-desktop-arm64.iso" \
        "$ISO_ARM64/ubuntu-${UBUNTU_LTS}-desktop-arm64.iso" "Ubuntu ${UBUNTU_LTS} LTS Desktop (ARM64)"
    download_iso "https://cdimage.ubuntu.com/releases/${UBUNTU_LTS}/release/ubuntu-${UBUNTU_LTS}-live-server-arm64.iso" \
        "$ISO_ARM64/ubuntu-${UBUNTU_LTS}-live-server-arm64.iso" "Ubuntu ${UBUNTU_LTS} LTS Live Server (ARM64)"

    ALPINE_ISO="$(curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/" | grep -oE 'alpine-standard-[0-9]+\.[0-9]+\.[0-9]+-aarch64\.iso' | sort -V | tail -1 || true)"
    if [[ -n "$ALPINE_ISO" ]]; then
        download_iso "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/$ALPINE_ISO" \
            "$ISO_ARM64/$ALPINE_ISO" "Alpine Linux ARM64 ($ALPINE_ISO)"
    fi

    DEBIAN_ISO="$(curl -fsSL "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/" | grep -oE 'debian-[0-9]+\.[0-9]+\.[0-9]+-arm64-netinst\.iso' | head -1 || true)"
    if [[ -n "$DEBIAN_ISO" ]]; then
        download_iso "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/$DEBIAN_ISO" \
            "$ISO_ARM64/$DEBIAN_ISO" "Debian ARM64 Netinst ($DEBIAN_ISO)"
    fi
fi

# 8. Generate Dynamic Architecture-Aware <USB>/ventoy/ventoy.json
echo "[*] Generating architecture-aware $VENTOY_DIR/ventoy.json..."
ALIAS_ENTRIES=()

for iso in "$ISO_X64"/*.iso; do
    [[ -f "$iso" ]] || continue
    fname="$(basename "$iso")"
    friendly="${fname%.iso}"
    if [[ "$fname" =~ [Ww]in11_([0-9A-Za-z]+) ]]; then friendly="Windows 11 ${BASH_REMATCH[1]} (English)"
    elif [[ "$fname" =~ ubuntu-([0-9.]+)-desktop ]]; then friendly="Ubuntu ${BASH_REMATCH[1]} LTS Desktop"
    elif [[ "$fname" =~ ubuntu-([0-9.]+)-live-server ]]; then friendly="Ubuntu ${BASH_REMATCH[1]} LTS Live Server"
    elif [[ "$fname" =~ cachyos ]]; then friendly="CachyOS Desktop Linux"
    elif [[ "$fname" =~ clonezilla-live-([0-9.-]+)-amd64 ]]; then friendly="Clonezilla Live ${BASH_REMATCH[1]}"
    fi
    ALIAS_ENTRIES+=("        { \"image\": \"/iso/x86_64/$fname\", \"alias\": \"[x64] $friendly\" }")
done

for iso in "$ISO_ARM64"/*.iso; do
    [[ -f "$iso" ]] || continue
    fname="$(basename "$iso")"
    friendly="${fname%.iso}"
    if [[ "$fname" =~ [Ww]in11_([0-9A-Za-z]+) ]]; then friendly="Windows 11 ${BASH_REMATCH[1]} (English)"
    elif [[ "$fname" =~ ubuntu-([0-9.]+)-desktop ]]; then friendly="Ubuntu ${BASH_REMATCH[1]} LTS Desktop"
    elif [[ "$fname" =~ ubuntu-([0-9.]+)-live-server ]]; then friendly="Ubuntu ${BASH_REMATCH[1]} LTS Live Server"
    elif [[ "$fname" =~ debian-([0-9.]+)-arm64-netinst ]]; then friendly="Debian ${BASH_REMATCH[1]} Netinst"
    elif [[ "$fname" =~ alpine-standard-([0-9.]+)-aarch64 ]]; then friendly="Alpine Linux ${BASH_REMATCH[1]} Standard"
    elif [[ "$fname" =~ proxmox-ve_([0-9.-]+)-arm64 ]]; then friendly="Proxmox VE ${BASH_REMATCH[1]}"
    fi
    ALIAS_ENTRIES+=("        { \"image\": \"/iso/arm64/$fname\", \"alias\": \"[ARM64] $friendly\" }")
done

ALIAS_JSON="$(printf '%s,\n' "${ALIAS_ENTRIES[@]}" | sed '$s/,$//')"

cat > "$VENTOY_DIR/ventoy.json" <<EOF
{
    "control": [
        { "VTOY_DEFAULT_SEARCH_ROOT": "/iso" },
        { "VTOY_DEFAULT_MENU_MODE": "1" },
        { "VTOY_TREE_VIEW_MENU_STYLE": "0" },
        { "VTOY_FILT_DOT_UNDERSCORE_FILE": "1" }
    ],
    "control_ia32": [
        { "VTOY_DEFAULT_SEARCH_ROOT": "/iso/x86_64" }
    ],
    "control_x86_64": [
        { "VTOY_DEFAULT_SEARCH_ROOT": "/iso/x86_64" }
    ],
    "control_aa64": [
        { "VTOY_DEFAULT_SEARCH_ROOT": "/iso/arm64" }
    ],
    "theme": {
        "file": "/ventoy/theme/theme.txt",
        "display_mode": "GUI"
    },
    "menu_class": [
        {
            "key": "ubuntu",
            "class": "ubuntu"
        }
    ],
    "menu_alias": [
$ALIAS_JSON
    ]
}
EOF
echo "[+] Wrote $VENTOY_DIR/ventoy.json with ${#ALIAS_ENTRIES[@]} ISO menu aliases."

# 9. Create Cross-Platform (Linux & macOS) QEMU Boot Test Launchers in <USB>/Tools/
if [[ "$SETUP_QEMU" -eq 1 || -d "$TOOLS_DIR" ]]; then
    echo "[*] Creating Linux/macOS QEMU test launchers in $TOOLS_DIR..."

    cat > "$TOOLS_DIR/test_ventoy_x86_64_uefi.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
USB_DEV="${1:-}"
if [[ -z "$USB_DEV" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
        USB_DEV="$(df /Volumes/Ventoy 2>/dev/null | tail -1 | awk '{print $1}' | sed -E 's/s[0-9]+$//' || true)"
    else
        PART_DEV="$(lsblk -o LABEL,PATH -nr 2>/dev/null | awk '$1 == "Ventoy" {print $2; exit}' || true)"
        [[ -n "$PART_DEV" ]] && USB_DEV="/dev/$(lsblk -no PKNAME "$PART_DEV" | head -1)"
    fi
fi
if [[ -z "$USB_DEV" ]]; then
    read -r -p "Enter Ventoy USB disk device (e.g. /dev/sdb or /dev/disk2): " USB_DEV
fi

OVMF_CODE=""
for p in \
    "/usr/share/OVMF/OVMF_CODE.fd" \
    "/usr/share/OVMF/OVMF_CODE_4M.fd" \
    "/usr/share/edk2/x64/OVMF_CODE.fd" \
    "/usr/share/qemu/edk2-x86_64-code.fd" \
    "/opt/homebrew/share/qemu/edk2-x86_64-code.fd" \
    "/usr/local/share/qemu/edk2-x86_64-code.fd"; do
    [[ -f "$p" ]] && { OVMF_CODE="$p"; break; }
done

if [[ -z "$OVMF_CODE" ]]; then
    echo "Could not find edk2-x86_64-code.fd / OVMF_CODE.fd. Install qemu / ovmf via apt, dnf, pacman, or brew." >&2
    exit 1
fi

echo "Starting QEMU x86_64 UEFI boot test on $USB_DEV (Read-Only Snapshot Mode)..."
sudo qemu-system-x86_64 \
    -name "Ventoy x86_64 UEFI Test (Snapshot Mode)" \
    -m 2048 -vga std \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive file="$USB_DEV",format=raw,media=disk,snapshot=on
EOF

    cat > "$TOOLS_DIR/test_ventoy_arm64_uefi.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
USB_DEV="${1:-}"
if [[ -z "$USB_DEV" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
        USB_DEV="$(df /Volumes/Ventoy 2>/dev/null | tail -1 | awk '{print $1}' | sed -E 's/s[0-9]+$//' || true)"
    else
        PART_DEV="$(lsblk -o LABEL,PATH -nr 2>/dev/null | awk '$1 == "Ventoy" {print $2; exit}' || true)"
        [[ -n "$PART_DEV" ]] && USB_DEV="/dev/$(lsblk -no PKNAME "$PART_DEV" | head -1)"
    fi
fi
if [[ -z "$USB_DEV" ]]; then
    read -r -p "Enter Ventoy USB disk device (e.g. /dev/sdb or /dev/disk2): " USB_DEV
fi

AA64_CODE=""
for p in \
    "/usr/share/AAVMF/AAVMF_CODE.fd" \
    "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd" \
    "/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw" \
    "/usr/share/qemu/edk2-aarch64-code.fd" \
    "/opt/homebrew/share/qemu/edk2-aarch64-code.fd" \
    "/usr/local/share/qemu/edk2-aarch64-code.fd"; do
    [[ -f "$p" ]] && { AA64_CODE="$p"; break; }
done

if [[ -z "$AA64_CODE" ]]; then
    echo "Could not find edk2-aarch64-code.fd / QEMU_EFI.fd. Install qemu-system-arm / qemu-efi-aarch64 or brew install qemu." >&2
    exit 1
fi

echo "Starting QEMU ARM64 (aarch64) UEFI boot test on $USB_DEV (Read-Only Snapshot Mode)..."
sudo qemu-system-aarch64 \
    -name "Ventoy ARM64 UEFI Test (Snapshot Mode)" \
    -M virt -cpu cortex-a72 -m 2048 \
    -device ramfb -device qemu-xhci -device usb-kbd -device usb-mouse \
    -drive if=pflash,format=raw,readonly=on,file="$AA64_CODE" \
    -drive if=none,id=usbdisk,file="$USB_DEV",format=raw,snapshot=on \
    -device usb-storage,drive=usbdisk,bootindex=0
EOF

    cat > "$TOOLS_DIR/test_ventoy_x86_bios.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
USB_DEV="${1:-}"
if [[ -z "$USB_DEV" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
        USB_DEV="$(df /Volumes/Ventoy 2>/dev/null | tail -1 | awk '{print $1}' | sed -E 's/s[0-9]+$//' || true)"
    else
        PART_DEV="$(lsblk -o LABEL,PATH -nr 2>/dev/null | awk '$1 == "Ventoy" {print $2; exit}' || true)"
        [[ -n "$PART_DEV" ]] && USB_DEV="/dev/$(lsblk -no PKNAME "$PART_DEV" | head -1)"
    fi
fi
if [[ -z "$USB_DEV" ]]; then
    read -r -p "Enter Ventoy USB disk device (e.g. /dev/sdb or /dev/disk2): " USB_DEV
fi

echo "Starting QEMU x86 Legacy BIOS boot test on $USB_DEV (Read-Only Snapshot Mode)..."
sudo qemu-system-x86_64 \
    -name "Ventoy x86 Legacy BIOS Test (Snapshot Mode)" \
    -m 1024 -vga std \
    -drive file="$USB_DEV",format=raw,media=disk,snapshot=on
EOF

    chmod +x "$TOOLS_DIR/test_ventoy_x86_64_uefi.sh" \
             "$TOOLS_DIR/test_ventoy_arm64_uefi.sh" \
             "$TOOLS_DIR/test_ventoy_x86_bios.sh" 2>/dev/null || true
    echo "[+] Created test_ventoy_*.sh scripts in $TOOLS_DIR"
fi

echo ""
echo "=================================================================="
echo "  Multi-Architecture Ventoy Setup Complete on $USB_MOUNT!"
echo "=================================================================="
