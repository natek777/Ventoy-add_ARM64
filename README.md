# `add-arm46-ventoy` — Cross-Platform (Windows, macOS, Linux) Dual-Architecture (`x86_64` & `ARM64`) Ventoy Setup & QEMU Test Suite

This directory provides a cross-platform, automated toolkit to turn a standard Ventoy installation (and portable Ventoy directory) into a **dual-architecture (`x86_64` + `ARM64` / `aarch64`)** bootable USB drive across **Windows**, **macOS**, and **Linux**, complete with architecture-filtered boot menus, UEFI Interactive Shell fallback support for MBR-formatted ARM64 disks, direct-to-USB ISO downloading, and one-click QEMU boot testing for both architectures.

---

## Included Scripts

| File | Platform | Description |
| :--- | :--- | :--- |
| [`Setup-VentoyMultiArch.ps1`](file:///C:/Users/natek/Downloads/ventoy-1.1.17/add-arm46-ventoy/Setup-VentoyMultiArch.ps1) | **Windows** (PowerShell 5.1+ / 7+) & **macOS / Linux** (`pwsh`) | Main PowerShell automation script. Auto-delegates to `setup-ventoy-multiarch.sh` when run under `pwsh` on macOS or Linux. |
| [`run-setup.cmd`](file:///C:/Users/natek/Downloads/ventoy-1.1.17/add-arm46-ventoy/run-setup.cmd) | **Windows** | Double-clickable interactive batch wrapper for `Setup-VentoyMultiArch.ps1`. |
| [`setup-ventoy-multiarch.sh`](file:///C:/Users/natek/Downloads/ventoy-1.1.17/add-arm46-ventoy/setup-ventoy-multiarch.sh) | **macOS & Linux** (Bash) | Native Bash script supporting `diskutil` (macOS) and `lsblk`/`blkid` (Linux) for automatic USB mount, block device, and `VTOYEFI` detection. |

---

## What It Does

1. **Unlocks Native `X64` / `ARM` / `ARM64` Ventoy Executables**
   * Copies `Ventoy2Disk_X64.exe`, `Ventoy2Disk_ARM.exe`, `Ventoy2Disk_ARM64.exe`, and `VentoyPlugson_X64.exe` from `altexe/` into the root of your Ventoy portable folder and syncs a full portable copy onto `<USB>/Tools/Ventoy/`.

2. **Patches the Hidden `VTOYEFI` Partition for Strict ARM64 UEFI Firmware**
   * While Ventoy installs `EFI/BOOT/BOOTAA64.EFI`, `BOOTX64.EFI`, and `BOOTIA32.EFI` into the 2nd hidden 32 MB FAT16 partition (`VTOYEFI`), some strict ARM64 UEFI implementations (including TianoCore EDK2 when booting from an MBR-partitioned USB drive) drop into the UEFI Interactive Shell instead of auto-booting MBR partition 2.
   * On **Windows**, **macOS**, and **Linux**, the script automatically locates/mounts the hidden `VTOYEFI` volume and writes `startup.nsh` containing `\EFI\BOOT\BOOTAA64.EFI` so any ARM64 UEFI Shell automatically chains straight into Ventoy's ARM64 bootloader.

3. **Organizes ISOs by Architecture & Builds `<USB>/ventoy/ventoy.json`**
   * Creates `<USB>/iso/x86_64/` and `<USB>/iso/arm64/` and automatically sorts any existing `.iso` files in `<USB>/iso/`.
   * Installs the Ventoy GUI theme to `<USB>/ventoy/theme/`.
   * Generates `<USB>/ventoy/ventoy.json` with architecture-specific `VTOY_DEFAULT_SEARCH_ROOT` directives:
     * **`control_ia32` & `control_x86_64`** $\rightarrow$ automatically filters the boot menu to `/iso/x86_64` on 32-bit/64-bit x86 PCs.
     * **`control_aa64`** $\rightarrow$ automatically filters the boot menu to `/iso/arm64` on ARM64 devices.
   * Automatically builds clean `[x64]` and `[ARM64]` `menu_alias` entries for every ISO present.

4. **Downloads Official LTS & Latest ISOs Directly to the USB Drive (`-DownloadISOs` / `--download-isos`)**
   * Downloads directly onto the Ventoy USB drive so zero space is required on your local OS drive:
     * **Ubuntu 26.04 LTS Desktop & Live Server** (`amd64` $\rightarrow$ `/iso/x86_64/`, `arm64` $\rightarrow$ `/iso/arm64/`)
     * **Windows 11 ARM64 (Latest Retail Build)** (fetched dynamically via official Microsoft links using `Fido.ps1` on Windows $\rightarrow$ `/iso/arm64/`)
     * **Debian Netinst (`arm64`)** (latest stable release $\rightarrow$ `/iso/arm64/`)
     * **Alpine Linux Standard (`aarch64`)** (latest stable release $\rightarrow$ `/iso/arm64/`)

5. **Sets Up QEMU (`x86_64` + `aarch64`) & Cross-Platform One-Click Test Launchers (`-SetupQEMU` / `--setup-qemu`)**
   * On **Windows**, downloads and extracts portable **QEMU 11.1.0** (including `qemu-system-x86_64.exe`, `qemu-system-aarch64.exe`, and `edk2-x86_64` / `edk2-aarch64` UEFI firmware) directly to `<USB>:\Tools\QEMU\`.
   * Generates both **Windows (`.cmd`)** and **Linux/macOS (`.sh`)** test launchers inside `<USB>/Tools/` that test your live USB drive in **read-only snapshot mode** (`snapshot=on` / `NOWRITE`) so OS file locks are safe and no writes hit the USB drive:
     * **`Test_Ventoy_x86_64_UEFI.cmd`** / **`test_ventoy_x86_64_uefi.sh`** — Boots the USB drive in QEMU `x86_64` with TianoCore EDK2 UEFI firmware.
     * **`Test_Ventoy_ARM64_UEFI.cmd`** / **`test_ventoy_arm64_uefi.sh`** — Boots the USB drive in QEMU `aarch64` (`-M virt -cpu cortex-a72`) with TianoCore EDK2 ARM64 UEFI firmware (`bootindex=0` + `startup.nsh`).
     * **`Test_Ventoy_x86_BIOS.cmd`** / **`test_ventoy_x86_bios.sh`** — Boots the USB drive in Legacy x86 BIOS mode.

---

## Quick Start

### 1. Windows

#### Option A: Interactive Batch Launcher
Double-click [`run-setup.cmd`](file:///C:/Users/natek/Downloads/ventoy-1.1.17/add-arm46-ventoy/run-setup.cmd) inside `add-arm46-ventoy\`. It will prompt for your Ventoy portable folder path (defaulting to the parent folder), target disk number (or auto-detect), and whether to download ISOs and set up QEMU.

#### Option B: PowerShell Command Line
Run [`Setup-VentoyMultiArch.ps1`](file:///C:/Users/natek/Downloads/ventoy-1.1.17/add-arm46-ventoy/Setup-VentoyMultiArch.ps1) directly from PowerShell:

```powershell
# Full setup (auto-detects Ventoy drive, downloads missing ISOs, and sets up QEMU launchers):
.\add-arm46-ventoy\Setup-VentoyMultiArch.ps1 `
    -VentoyPath "C:\Users\natek\Downloads\ventoy-1.1.17" `
    -DiskNumber 1 `
    -DriveLetter "D" `
    -DownloadISOs `
    -SetupQEMU

# Quick re-index (organizes new ISOs in D:\iso, refreshes ventoy.json aliases, and verifies VTOYEFI startup.nsh):
.\add-arm46-ventoy\Setup-VentoyMultiArch.ps1 -VentoyPath "C:\Users\natek\Downloads\ventoy-1.1.17"
```

---

### 2. macOS & Linux

Run [`setup-ventoy-multiarch.sh`](file:///C:/Users/natek/Downloads/ventoy-1.1.17/add-arm46-ventoy/setup-ventoy-multiarch.sh) (or `pwsh ./add-arm46-ventoy/Setup-VentoyMultiArch.ps1`):

```bash
chmod +x ./add-arm46-ventoy/setup-ventoy-multiarch.sh

# Auto-detects mounted Ventoy USB drive (/Volumes/Ventoy on macOS or /media/$USER/Ventoy on Linux),
# patches VTOYEFI/startup.nsh, downloads ISOs, generates ventoy.json, and creates QEMU .sh launchers:
./add-arm46-ventoy/setup-ventoy-multiarch.sh --download-isos --setup-qemu

# Or specify paths explicitly:
./add-arm46-ventoy/setup-ventoy-multiarch.sh \
    --ventoy-path /path/to/ventoy-1.1.17 \
    --mount /Volumes/Ventoy \
    --device /dev/disk2 \
    --setup-qemu
```

#### Installing QEMU & UEFI Firmware on macOS / Linux for Boot Testing
To run `<USB>/Tools/test_ventoy_x86_64_uefi.sh`, `test_ventoy_arm64_uefi.sh`, or `test_ventoy_x86_bios.sh` on macOS or Linux:
* **macOS (Homebrew)**:
  ```bash
  brew install qemu
  ```
* **Ubuntu / Debian**:
  ```bash
  sudo apt update && sudo apt install -y qemu-system-x86 qemu-system-arm ovmf qemu-efi-aarch64
  ```
* **Fedora / RHEL**:
  ```bash
  sudo dnf install -y qemu-system-x86 qemu-system-aarch64 edk2-ovmf edk2-aarch64
  ```
* **Arch Linux / CachyOS**:
  ```bash
  sudo pacman -S --needed qemu-full edk2-ovmf edk2-armvirt
  ```

Then run any test launcher directly from `<USB>/Tools/`:
```bash
/Volumes/Ventoy/Tools/test_ventoy_arm64_uefi.sh
/Volumes/Ventoy/Tools/test_ventoy_x86_64_uefi.sh
/Volumes/Ventoy/Tools/test_ventoy_x86_bios.sh
```

---

## Directory Layout Created on the Ventoy USB Drive

```text
<USB_Drive>/
├── iso/
│   ├── x86_64/
│   │   ├── Win11_25H2_English_x64_v2.iso
│   │   ├── ubuntu-26.04-desktop-amd64.iso
│   │   ├── ubuntu-26.04-live-server-amd64.iso
│   │   ├── cachyos-desktop-linux-260426.iso
│   │   └── clonezilla-live-3.2.2-15-amd64.iso
│   └── arm64/
│       ├── Win11_26H2_English_arm64.iso
│       ├── ubuntu-26.04-desktop-arm64.iso
│       ├── ubuntu-26.04-live-server-arm64.iso
│       ├── debian-13.7.0-arm64-netinst.iso
│       ├── alpine-standard-3.24.3-aarch64.iso
│       └── proxmox-ve_9.2-1-arm64.iso
├── ventoy/
│   ├── ventoy.json                   # Architecture-aware search roots & aliases
│   └── theme/                        # Ventoy GUI theme
└── Tools/
    ├── Ventoy/                       # Portable Ventoy (x86, x64, ARM, ARM64 exes + add-arm46-ventoy toolkit)
    ├── QEMU/                         # Portable QEMU 11.1.0 + EDK2 UEFI firmwares (Windows)
    ├── Temp/                         # Temporary NVRAM vars & Fido script
    ├── Test_Ventoy_x86_64_UEFI.cmd   # Windows: One-click x86_64 UEFI boot test
    ├── Test_Ventoy_ARM64_UEFI.cmd    # Windows: One-click ARM64 UEFI boot test
    ├── Test_Ventoy_x86_BIOS.cmd      # Windows: One-click x86 Legacy BIOS boot test
    ├── test_ventoy_x86_64_uefi.sh    # Linux/macOS: One-click x86_64 UEFI boot test
    ├── test_ventoy_arm64_uefi.sh     # Linux/macOS: One-click ARM64 UEFI boot test
    └── test_ventoy_x86_bios.sh       # Linux/macOS: One-click x86 Legacy BIOS boot test
```
