<#
.SYNOPSIS
    Configures an existing Ventoy USB disk and portable Ventoy folder for seamless dual-architecture (x86_64 + ARM64) booting,
    organizes or downloads LTS/latest ISOs directly onto the Ventoy drive, installs portable QEMU testing tools, and patches
    the hidden VTOYEFI partition with startup.nsh for strict ARM64 UEFI firmware compatibility.

.DESCRIPTION
    This script automates the complete multi-architecture setup of a Ventoy drive:
    1. Copies native ARM/ARM64/X64 executables from `altexe\` into the main Ventoy portable folder and onto `<Drive>:\Tools\Ventoy`.
    2. Creates `<Drive>:\iso\x86_64` and `<Drive>:\iso\arm64` and automatically sorts any existing ISOs in `<Drive>:\iso`.
    3. Writes `startup.nsh` (`\EFI\BOOT\BOOTAA64.EFI`) to the hidden `VTOYEFI` FAT partition on the target disk so strict ARM64
       UEFI implementations (and UEFI Interactive Shells on MBR disks) automatically launch the ARM64 Ventoy bootloader.
    4. Installs Ventoy GUI theme files and generates an architecture-aware `<Drive>:\ventoy\ventoy.json` that automatically filters
       `/iso/x86_64` on x86/x64 systems and `/iso/arm64` on ARM64 systems, with human-readable menu aliases.
    5. Optionally downloads official ARM64 & x86_64 ISOs (Ubuntu LTS Desktop/Server, Windows 11 ARM64 via Fido, Debian ARM64,
       Alpine ARM64) directly to `<Drive>:\iso\` without consuming `C:` drive space.
    6. Optionally downloads & extracts portable QEMU (with `qemu-system-x86_64`, `qemu-system-aarch64`, and EDK2 UEFI firmware)
       to `<Drive>:\Tools\QEMU` and generates one-click, read-only snapshot test launchers (`Test_Ventoy_x86_64_UEFI.cmd`,
       `Test_Ventoy_ARM64_UEFI.cmd`, and `Test_Ventoy_x86_BIOS.cmd`).

.PARAMETER VentoyPath
    Path to the Ventoy installation / portable directory (defaults to parent directory if located inside Ventoy folder, or current directory).

.PARAMETER DiskNumber
    Target Windows Disk Number where Ventoy is installed (e.g., 1). If omitted, auto-detects the disk containing a `VTOYEFI` / `Ventoy` volume.

.PARAMETER DriveLetter
    Drive letter of the main Ventoy data partition (e.g., 'D'). If omitted, auto-detects from the target DiskNumber.

.PARAMETER DownloadISOs
    Switch to download missing standard ISOs (Ubuntu 26.04 LTS Desktop & Server, Windows 11 ARM64, Debian Netinst ARM64, Alpine ARM64)
    directly onto the Ventoy USB drive.

.PARAMETER SetupQEMU
    Switch to download and extract portable QEMU to `<Drive>:\Tools\QEMU` and create the `.cmd` test launchers.

.EXAMPLE
    .\Setup-VentoyMultiArch.ps1 -VentoyPath "C:\Users\natek\Downloads\ventoy-1.1.17" -DiskNumber 1 -DownloadISOs -SetupQEMU
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$VentoyPath = (Split-Path -Parent $PSScriptRoot),

    [Parameter(Mandatory = $false)]
    [int]$DiskNumber = -1,

    [Parameter(Mandatory = $false)]
    [string]$DriveLetter = "",

    [Parameter(Mandatory = $false)]
    [string]$UbuntuLTSVersion = "26.04",

    [Parameter(Mandatory = $false)]
    [switch]$DownloadISOs,

    [Parameter(Mandatory = $false)]
    [switch]$SetupQEMU
)

$ErrorActionPreference = "Stop"

# If invoked under PowerShell 7+ (pwsh) on Linux or macOS, delegate to setup-ventoy-multiarch.sh
if ($PSVersionTable.PSVersion.Major -ge 6 -and (-not $IsWindows)) {
    $shScript = Join-Path $PSScriptRoot "setup-ventoy-multiarch.sh"
    $shArgs = @("--ventoy-path", $VentoyPath, "--ubuntu-version", $UbuntuLTSVersion)
    if ($DriveLetter) { $shArgs += @("--mount", $DriveLetter) }
    if ($DownloadISOs) { $shArgs += "--download-isos" }
    if ($SetupQEMU)    { $shArgs += "--setup-qemu" }
    & bash $shScript @shArgs
    exit $LASTEXITCODE
}

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "   Ventoy Multi-Architecture (x86_64 + ARM64) Setup Automation    " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# 1. Validate or Prompt for Ventoy Portable Folder Path
if (-not (Test-Path (Join-Path $VentoyPath "Ventoy2Disk.exe"))) {
    if (Test-Path ".\Ventoy2Disk.exe") {
        $VentoyPath = (Resolve-Path ".").Path
    } else {
        $inputPath = Read-Host "Enter path to your Ventoy portable folder (containing Ventoy2Disk.exe)"
        if (Test-Path (Join-Path $inputPath "Ventoy2Disk.exe")) {
            $VentoyPath = (Resolve-Path $inputPath).Path
        } else {
            throw "Could not find Ventoy2Disk.exe in '$VentoyPath' or '$inputPath'. Please provide a valid -VentoyPath."
        }
    }
}
Write-Host "[+] Using Ventoy Portable Folder: $VentoyPath" -ForegroundColor Green

# 2. Auto-detect DiskNumber and DriveLetter if not provided
$vtoyEfiVol = Get-Volume | Where-Object { $_.FileSystemLabel -eq "VTOYEFI" } | Select-Object -First 1

if ($DiskNumber -lt 0) {
    if ($DriveLetter -ne "") {
        $dl = $DriveLetter.TrimEnd(':').Substring(0, 1)
        $part = Get-Partition -DriveLetter $dl -ErrorAction SilentlyContinue
        if ($part) { $DiskNumber = $part.DiskNumber }
    }
    if ($DiskNumber -lt 0) {
        $ventoyDataVol = Get-Volume | Where-Object { $_.FileSystemLabel -eq "Ventoy" -and $_.DriveType -eq "Removable" } | Select-Object -First 1
        if ($ventoyDataVol -and $ventoyDataVol.DriveLetter) {
            $part = Get-Partition -DriveLetter $ventoyDataVol.DriveLetter -ErrorAction SilentlyContinue
            if ($part) {
                $DiskNumber = $part.DiskNumber
                $DriveLetter = $ventoyDataVol.DriveLetter
            }
        }
    }
    if ($DiskNumber -lt 0) {
        Get-Disk | Select-Object Number, FriendlyName, Size, PartitionStyle | Format-Table -AutoSize
        $DiskNumber = [int](Read-Host "Enter the Disk Number of your Ventoy USB drive (e.g. 1)")
    }
}

if ([string]::IsNullOrWhiteSpace($DriveLetter)) {
    $dataPart = Get-Partition -DiskNumber $DiskNumber | Where-Object { $_.DriveLetter -and $_.Size -gt 64MB } | Select-Object -First 1
    if ($dataPart) {
        $DriveLetter = [string]$dataPart.DriveLetter
    } else {
        $DriveLetter = (Read-Host "Enter the Drive Letter of your Ventoy USB data partition (e.g. D)").TrimEnd(':')
    }
} else {
    $DriveLetter = $DriveLetter.TrimEnd(':')
}

$DriveRoot = "${DriveLetter}:\"
if (-not (Test-Path $DriveRoot)) {
    throw "Target Ventoy data drive '$DriveRoot' does not exist or is not mounted."
}
Write-Host "[+] Target Ventoy Disk: Disk $DiskNumber ($DriveRoot)" -ForegroundColor Green

# 3. Copy Native ARM / ARM64 / X64 Executables from altexe\
$altExeDir = Join-Path $VentoyPath "altexe"
if (Test-Path $altExeDir) {
    Write-Host "[*] Copying native X64 / ARM / ARM64 executables from altexe\ to $VentoyPath..." -ForegroundColor Yellow
    Copy-Item -Path (Join-Path $altExeDir "*.exe") -Destination $VentoyPath -Force
}

# 4. Create Directory Structure on USB Drive & Copy Portable Ventoy Suite
$isoRoot    = Join-Path $DriveRoot "iso"
$isoX64     = Join-Path $isoRoot "x86_64"
$isoArm64   = Join-Path $isoRoot "arm64"
$ventoyDir  = Join-Path $DriveRoot "ventoy"
$toolsDir   = Join-Path $DriveRoot "Tools"
$toolsVtoy  = Join-Path $toolsDir "Ventoy"
$toolsTemp  = Join-Path $toolsDir "Temp"

New-Item -ItemType Directory -Force -Path $isoX64, $isoArm64, $ventoyDir, $toolsVtoy, $toolsTemp | Out-Null

Write-Host "[*] Syncing portable Ventoy suite (with ARM/X64 tools) to $toolsVtoy..." -ForegroundColor Yellow
Get-ChildItem -Path $VentoyPath -Exclude "add-arm46-ventoy", "add-arm64-ventoy", "RMPrepUSB*" | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $toolsVtoy -Recurse -Force
}

$themeSrc = Join-Path $VentoyPath "plugin\ventoy\theme"
$themeDst = Join-Path $ventoyDir "theme"
if (Test-Path $themeSrc) {
    Write-Host "[*] Installing Ventoy GUI theme to $themeDst..." -ForegroundColor Yellow
    Copy-Item -Path $themeSrc -Destination $themeDst -Recurse -Force
}

# 5. Organize Existing ISOs in <Drive>:\iso into x86_64 and arm64 Subfolders
Write-Host "[*] Organizing existing ISOs in $isoRoot into x86_64 and arm64 folders..." -ForegroundColor Yellow
Get-ChildItem -Path $isoRoot -File -Filter "*.iso" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -match "(?i)(arm64|aarch64)") {
        Write-Host "    -> Moving $($_.Name) to iso\arm64\"
        Move-Item -Path $_.FullName -Destination $isoArm64 -Force
    } else {
        Write-Host "    -> Moving $($_.Name) to iso\x86_64\"
        Move-Item -Path $_.FullName -Destination $isoX64 -Force
    }
}

# 6. Patch Hidden VTOYEFI Partition with startup.nsh for Strict ARM64 UEFI Booting
Write-Host "[*] Checking hidden VTOYEFI partition for ARM64 startup.nsh fallback..." -ForegroundColor Yellow
if ($vtoyEfiVol) {
    $startupNshPath = $vtoyEfiVol.Path + "startup.nsh"
    Set-Content -LiteralPath $startupNshPath -Value "\EFI\BOOT\BOOTAA64.EFI" -Encoding Ascii
    Write-Host "[+] Wrote \EFI\BOOT\BOOTAA64.EFI to $($startupNshPath)" -ForegroundColor Green
} else {
    Write-Warning "Could not locate mounted VTOYEFI volume label via Get-Volume. Make sure Ventoy is installed on Disk $DiskNumber."
}

# 7. Optional: Download Official ISOs Directly to <Drive>:\iso\
if ($DownloadISOs) {
    Write-Host "[*] Downloading requested x86_64 & ARM64 ISOs directly to $isoRoot (bypassing C: drive)..." -ForegroundColor Yellow

    function Invoke-DirectDownload([string]$Url, [string]$DestPath, [string]$Label) {
        if (Test-Path $DestPath) {
            $existing = Get-Item $DestPath
            if ($existing.Length -gt 100MB) {
                Write-Host "    [=] $Label already exists ($([math]::Round($existing.Length / 1GB, 2)) GB). Skipping." -ForegroundColor Gray
                return
            }
        }
        Write-Host "    [v] Downloading $Label -> $DestPath ..." -ForegroundColor Cyan
        & curl.exe -L $Url -o $DestPath
    }

    # Ubuntu LTS (x86_64 & ARM64 Desktop + Live Server)
    Invoke-DirectDownload "https://releases.ubuntu.com/$UbuntuLTSVersion/ubuntu-$UbuntuLTSVersion-desktop-amd64.iso" `
        (Join-Path $isoX64 "ubuntu-$UbuntuLTSVersion-desktop-amd64.iso") "Ubuntu $UbuntuLTSVersion LTS Desktop (x86_64)"
    Invoke-DirectDownload "https://releases.ubuntu.com/$UbuntuLTSVersion/ubuntu-$UbuntuLTSVersion-live-server-amd64.iso" `
        (Join-Path $isoX64 "ubuntu-$UbuntuLTSVersion-live-server-amd64.iso") "Ubuntu $UbuntuLTSVersion LTS Live Server (x86_64)"
    Invoke-DirectDownload "https://cdimage.ubuntu.com/releases/$UbuntuLTSVersion/release/ubuntu-$UbuntuLTSVersion-desktop-arm64.iso" `
        (Join-Path $isoArm64 "ubuntu-$UbuntuLTSVersion-desktop-arm64.iso") "Ubuntu $UbuntuLTSVersion LTS Desktop (ARM64)"
    Invoke-DirectDownload "https://cdimage.ubuntu.com/releases/$UbuntuLTSVersion/release/ubuntu-$UbuntuLTSVersion-live-server-arm64.iso" `
        (Join-Path $isoArm64 "ubuntu-$UbuntuLTSVersion-live-server-arm64.iso") "Ubuntu $UbuntuLTSVersion LTS Live Server (ARM64)"

    # Alpine Linux Standard (ARM64)
    try {
        $alpineLinks = (Invoke-WebRequest -Uri "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/" -UseBasicParsing).Links
        $latestAlpine = $alpineLinks | Where-Object { $_.href -match "^alpine-standard-[0-9]+\.[0-9]+\.[0-9]+-aarch64\.iso$" } | Select-Object -Last 1 -ExpandProperty href
        if ($latestAlpine) {
            Invoke-DirectDownload "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/$latestAlpine" `
                (Join-Path $isoArm64 $latestAlpine) "Alpine Linux ARM64 ($latestAlpine)"
        }
    } catch {
        Write-Warning "Failed to query latest Alpine ARM64 ISO: $_"
    }

    # Debian Netinst (ARM64)
    try {
        $debLinks = (Invoke-WebRequest -Uri "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/" -UseBasicParsing).Links
        $latestDeb = $debLinks | Where-Object { $_.href -match "^debian-[0-9]+\.[0-9]+\.[0-9]+-arm64-netinst\.iso$" } | Select-Object -First 1 -ExpandProperty href
        if ($latestDeb) {
            Invoke-DirectDownload "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/$latestDeb" `
                (Join-Path $isoArm64 $latestDeb) "Debian ARM64 Netinst ($latestDeb)"
        }
    } catch {
        Write-Warning "Failed to query latest Debian ARM64 ISO: $_"
    }

    # Windows 11 ARM64 via Fido.ps1
    $existingWinArm = Get-ChildItem -Path $isoArm64 -Filter "*Win11*arm64*.iso" -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 3GB }
    if (-not $existingWinArm) {
        try {
            $fidoPath = Join-Path $toolsTemp "Fido.ps1"
            Invoke-WebRequest -Uri "https://github.com/pbatard/Fido/raw/master/Fido.ps1" -OutFile $fidoPath -UseBasicParsing
            $winArmUrl = & $fidoPath -Win 11 -Arch arm64 -Lang "English" -GetUrl | Select-Object -First 1
            if ($winArmUrl -match "^https?://") {
                Invoke-DirectDownload $winArmUrl (Join-Path $isoArm64 "Win11_English_arm64.iso") "Windows 11 ARM64 (English)"
            }
        } catch {
            Write-Warning "Could not automatically fetch Windows 11 ARM64 URL via Fido.ps1: $_"
        }
    } else {
        Write-Host "    [=] Windows 11 ARM64 ISO already present ($($existingWinArm[0].Name)). Skipping." -ForegroundColor Gray
    }
}

# 8. Generate Dynamic Architecture-Aware <Drive>:\ventoy\ventoy.json
Write-Host "[*] Generating architecture-aware ventoy.json..." -ForegroundColor Yellow
$aliases = @()

Get-ChildItem -Path $isoX64 -File -Filter "*.iso" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
    $friendly = $_.BaseName
    if ($_.Name -match "(?i)Win11_([0-9A-Z]+)") { $friendly = "Windows 11 $($Matches[1]) (English)" }
    elseif ($_.Name -match "(?i)ubuntu-([0-9.]+)-desktop") { $friendly = "Ubuntu $($Matches[1]) LTS Desktop" }
    elseif ($_.Name -match "(?i)ubuntu-([0-9.]+)-live-server") { $friendly = "Ubuntu $($Matches[1]) LTS Live Server" }
    elseif ($_.Name -match "(?i)cachyos") { $friendly = "CachyOS Desktop Linux" }
    elseif ($_.Name -match "(?i)clonezilla-live-([0-9.-]+)-amd64") { $friendly = "Clonezilla Live $($Matches[1])" }
    $aliases += [ordered]@{
        image = "/iso/x86_64/$($_.Name)"
        alias = "[x64] $friendly"
    }
}

Get-ChildItem -Path $isoArm64 -File -Filter "*.iso" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
    $friendly = $_.BaseName
    if ($_.Name -match "(?i)Win11_([0-9A-Z]+)") { $friendly = "Windows 11 $($Matches[1]) (English)" }
    elseif ($_.Name -match "(?i)ubuntu-([0-9.]+)-desktop") { $friendly = "Ubuntu $($Matches[1]) LTS Desktop" }
    elseif ($_.Name -match "(?i)ubuntu-([0-9.]+)-live-server") { $friendly = "Ubuntu $($Matches[1]) LTS Live Server" }
    elseif ($_.Name -match "(?i)debian-([0-9.]+)-arm64-netinst") { $friendly = "Debian $($Matches[1]) Netinst" }
    elseif ($_.Name -match "(?i)alpine-standard-([0-9.]+)-aarch64") { $friendly = "Alpine Linux $($Matches[1]) Standard" }
    elseif ($_.Name -match "(?i)proxmox-ve_([0-9.-]+)-arm64") { $friendly = "Proxmox VE $($Matches[1])" }
    $aliases += [ordered]@{
        image = "/iso/arm64/$($_.Name)"
        alias = "[ARM64] $friendly"
    }
}

$ventoyConfig = [ordered]@{
    control = @(
        @{ VTOY_DEFAULT_SEARCH_ROOT = "/iso" },
        @{ VTOY_DEFAULT_MENU_MODE = "1" },
        @{ VTOY_TREE_VIEW_MENU_STYLE = "0" },
        @{ VTOY_FILT_DOT_UNDERSCORE_FILE = "1" }
    )
    control_ia32 = @(
        @{ VTOY_DEFAULT_SEARCH_ROOT = "/iso/x86_64" }
    )
    control_x86_64 = @(
        @{ VTOY_DEFAULT_SEARCH_ROOT = "/iso/x86_64" }
    )
    control_aa64 = @(
        @{ VTOY_DEFAULT_SEARCH_ROOT = "/iso/arm64" }
    )
    theme = [ordered]@{
        file = "/ventoy/theme/theme.txt"
        display_mode = "GUI"
    }
    menu_class = @(
        @{ key = "ubuntu"; class = "ubuntu" }
    )
    menu_alias = $aliases
}

$ventoyJsonPath = Join-Path $ventoyDir "ventoy.json"
$ventoyConfig | ConvertTo-Json -Depth 6 | Set-Content -Path $ventoyJsonPath -Encoding UTF8
Write-Host "[+] Wrote $ventoyJsonPath with $($aliases.Count) ISO menu aliases." -ForegroundColor Green

# 9. Optional: Install Portable QEMU & Generate One-Click Boot Test Launchers
$qemuDir = Join-Path $toolsDir "QEMU"
if ($SetupQEMU -or (Test-Path (Join-Path $qemuDir "qemu-system-aarch64.exe"))) {
    if (-not (Test-Path (Join-Path $qemuDir "qemu-system-aarch64.exe"))) {
        Write-Host "[*] Downloading & extracting portable QEMU (x86_64 + ARM64 + EDK2 UEFI) to $qemuDir..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Force -Path $qemuDir | Out-Null
        $qemuInstaller = Join-Path $toolsTemp "qemu-setup.exe"
        & curl.exe -L "https://qemu.weilnetz.de/w64/2026/qemu-w64-setup-20260811.exe" -o $qemuInstaller
        $sevenZip = "C:\Program Files\7-Zip\7z.exe"
        if (-not (Test-Path $sevenZip)) {
            $sevenZipCmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
            if ($sevenZipCmd) { $sevenZip = $sevenZipCmd.Source }
        }
        if (Test-Path $sevenZip) {
            & $sevenZip x $qemuInstaller -o"$qemuDir" -y | Out-Null
            Remove-Item $qemuInstaller -Force -ErrorAction SilentlyContinue
            Write-Host "[+] Portable QEMU extracted to $qemuDir" -ForegroundColor Green
        } else {
            Write-Warning "7-Zip not found at C:\Program Files\7-Zip\7z.exe. Please extract $qemuInstaller manually to $qemuDir."
        }
    }

    # Create Test_Ventoy_x86_64_UEFI.cmd
    $cmdX64 = @"
@echo off
title Test Ventoy Disk $DiskNumber - x86_64 UEFI
echo Starting QEMU x86_64 UEFI boot test on Disk $DiskNumber (Read-Only Snapshot Mode)...
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges to read PhysicalDrive$DiskNumber...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
set TEMP=${DriveLetter}:\Tools\Temp
set TMP=${DriveLetter}:\Tools\Temp
if not exist "${DriveLetter}:\Tools\Temp\x86_64-vars.fd" copy /Y "${DriveLetter}:\Tools\QEMU\share\edk2-i386-vars.fd" "${DriveLetter}:\Tools\Temp\x86_64-vars.fd" >nul
"${DriveLetter}:\Tools\QEMU\qemu-system-x86_64.exe" -L "${DriveLetter}:\Tools\QEMU\share" -name "Ventoy Disk $DiskNumber - x86_64 UEFI Test (Snapshot Mode)" -m 2048 -vga std -drive if=pflash,format=raw,readonly=on,file="${DriveLetter}:\Tools\QEMU\share\edk2-x86_64-code.fd" -drive if=pflash,format=raw,file="${DriveLetter}:\Tools\Temp\x86_64-vars.fd" -drive file=\\.\PhysicalDrive$DiskNumber,format=raw,media=disk,snapshot=on
"@
    Set-Content -Path (Join-Path $toolsDir "Test_Ventoy_x86_64_UEFI.cmd") -Value $cmdX64 -Encoding Ascii

    # Create Test_Ventoy_ARM64_UEFI.cmd
    $cmdArm64 = @"
@echo off
title Test Ventoy Disk $DiskNumber - ARM64 UEFI
echo Starting QEMU ARM64 (aarch64) UEFI boot test on Disk $DiskNumber (Read-Only Snapshot Mode)...
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges to read PhysicalDrive$DiskNumber...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
set TEMP=${DriveLetter}:\Tools\Temp
set TMP=${DriveLetter}:\Tools\Temp
if not exist "${DriveLetter}:\Tools\Temp\arm64-vars.fd" copy /Y "${DriveLetter}:\Tools\QEMU\share\edk2-arm-vars.fd" "${DriveLetter}:\Tools\Temp\arm64-vars.fd" >nul
"${DriveLetter}:\Tools\QEMU\qemu-system-aarch64.exe" -L "${DriveLetter}:\Tools\QEMU\share" -name "Ventoy Disk $DiskNumber - ARM64 UEFI Test (Snapshot Mode)" -M virt -cpu cortex-a72 -m 2048 -device ramfb -device qemu-xhci -device usb-kbd -device usb-mouse -drive if=pflash,format=raw,readonly=on,file="${DriveLetter}:\Tools\QEMU\share\edk2-aarch64-code.fd" -drive if=pflash,format=raw,file="${DriveLetter}:\Tools\Temp\arm64-vars.fd" -drive if=none,id=usbdisk,file=\\.\PhysicalDrive$DiskNumber,format=raw,snapshot=on -device usb-storage,drive=usbdisk,bootindex=0
"@
    Set-Content -Path (Join-Path $toolsDir "Test_Ventoy_ARM64_UEFI.cmd") -Value $cmdArm64 -Encoding Ascii

    # Create Test_Ventoy_x86_BIOS.cmd (uses RMPrepUSB if present, otherwise QEMU SeaBIOS)
    $rmPrepQemu = Join-Path $VentoyPath "RMPrepUSB_Portable_v2.1.746\QEMU\StartFromUSB.cmd"
    if (Test-Path $rmPrepQemu) {
        $cmdBios = @"
@echo off
title Test Ventoy Disk $DiskNumber - x86 Legacy BIOS (RMPrepUSB)
echo Starting RMPrepUSB QEMU x86 Legacy BIOS boot test on Disk $DiskNumber...
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges to read PhysicalDrive$DiskNumber...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
set TEMP=${DriveLetter}:\Tools\Temp
set TMP=${DriveLetter}:\Tools\Temp
call "$rmPrepQemu" $DiskNumber 1024 NOWRITE
"@
    } else {
        $cmdBios = @"
@echo off
title Test Ventoy Disk $DiskNumber - x86 Legacy BIOS
echo Starting QEMU x86 Legacy BIOS boot test on Disk $DiskNumber (Read-Only Snapshot Mode)...
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges to read PhysicalDrive$DiskNumber...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
set TEMP=${DriveLetter}:\Tools\Temp
set TMP=${DriveLetter}:\Tools\Temp
"${DriveLetter}:\Tools\QEMU\qemu-system-x86_64.exe" -L "${DriveLetter}:\Tools\QEMU\share" -name "Ventoy Disk $DiskNumber - x86 BIOS Test (Snapshot Mode)" -m 1024 -vga std -drive file=\\.\PhysicalDrive$DiskNumber,format=raw,media=disk,snapshot=on
"@
    }
    Set-Content -Path (Join-Path $toolsDir "Test_Ventoy_x86_BIOS.cmd") -Value $cmdBios -Encoding Ascii

    # Also generate Linux & macOS (.sh) QEMU test launchers with strict LF (\n) line endings so the USB drive can be tested on any OS
    $shX64 = @'
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
'@

    $shArm64 = @'
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
'@

    $shBios = @'
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
'@

    [System.IO.File]::WriteAllText((Join-Path $toolsDir "test_ventoy_x86_64_uefi.sh"), $shX64.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $toolsDir "test_ventoy_arm64_uefi.sh"),  $shArm64.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $toolsDir "test_ventoy_x86_bios.sh"),    $shBios.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))

    Write-Host "[+] Created Windows (.cmd) and Linux/macOS (.sh) QEMU test launchers in $toolsDir" -ForegroundColor Green
}

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host "   Multi-Architecture Ventoy Setup Complete on Disk $DiskNumber ($DriveRoot)!" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
