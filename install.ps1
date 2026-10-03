# install.ps1
# ──────────────────────────────────────────────────────────────────────
# Mosaico Tiling Window Manager — Windows Installer
#
# Usage:
#   .\install.ps1
#   .\install.ps1 -InstallDir "C:\Tools\mosaico" -NoConfig -NoAutostart
#
# This script downloads the latest release from GitHub, extracts the
# binary, adds it to your user PATH, and optionally generates default
# config files and enables autostart.
#
# Based on the official installer:
#   https://raw.githubusercontent.com/jmelosegui/mosaico/main/docs/install.ps1
# ──────────────────────────────────────────────────────────────────────

[CmdletBinding()]
param(
    # Where to install the mosaico.exe binary.
    # Defaults to %LOCALAPPDATA%\mosaico (same as the official installer).
    [string]$InstallDir = "$env:LOCALAPPDATA\mosaico",

    # Skip generating default config files with `mosaico init`.
    [switch]$NoConfig,

    # Skip enabling autostart (start on Windows boot).
    [switch]$NoAutostart,

    # Skip adding the install directory to the user PATH.
    [switch]$NoPath,

    # Force reinstall even if the same version is already present.
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ─── Constants ─────────────────────────────────────────────────────────
$Repo       = "jmelosegui/mosaico"
$AssetName  = "mosaico-windows-amd64.zip"
$ExeName    = "mosaico.exe"
$ConfigDir  = if ($env:XDG_CONFIG_HOME) {
    Join-Path $env:XDG_CONFIG_HOME "mosaico"
} else {
    Join-Path $env:USERPROFILE ".config\mosaico"
}

# ─── Helpers ───────────────────────────────────────────────────────────
function Write-Info {
    param([string]$Message)
    Write-Host "  ==> " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [!] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-Err {
    param([string]$Message)
    Write-Host "  [x] " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "── $Message " -ForegroundColor Cyan -NoNewline
    Write-Host ("─" * [Math]::Max(0, 60 - $Message.Length)) -ForegroundColor DarkGray
}

function Fail {
    param([string]$Message)
    Write-Err $Message
    exit 1
}

# ─── Prerequisite Checks ───────────────────────────────────────────────
Write-Host ""
Write-Host "Mosaico Installer" -ForegroundColor White
Write-Host "=================" -ForegroundColor DarkGray
Write-Host ""

Write-Step "Checking prerequisites"

# PowerShell version (needs 5.1+ for Invoke-RestMethod TLS defaults, though
# we set TLS manually below for older systems).
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Fail "PowerShell 5.1 or later is required. Detected: $($PSVersionTable.PSVersion)"
}
Write-Info "PowerShell $($PSVersionTable.PSVersion) detected"

# Architecture check — only amd64 builds are published.
$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne "AMD64") {
    Write-Warn "Detected architecture: $arch. Mosaico publishes amd64 builds only."
    Write-Warn "Continuing anyway — the binary may not run on this system."
} else {
    Write-Info "Architecture: AMD64"
}

# TLS 1.2+ for GitHub API and release downloads.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ─── Resolve Latest Release ────────────────────────────────────────────
Write-Step "Resolving latest release"

try {
    $headers = @{ "User-Agent" = "mosaico-installer" }
    $release = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/$Repo/releases/latest" `
        -Headers $headers
    $version = $release.tag_name
    Write-Info "Latest version: $version"
} catch {
    Fail "Could not determine latest version. Check https://github.com/$Repo/releases"
}

# ─── Check Existing Installation ───────────────────────────────────────
$exePath = Join-Path $InstallDir $ExeName
$existingVersion = $null

if (Test-Path $exePath) {
    try {
        $existingVersion = (& $exePath --version 2>$null) -replace '^mosaico\s+', ''
        Write-Info "Existing installation found: $existingVersion"
    } catch {
        Write-Warn "Existing binary found but could not read version"
    }

    if ($existingVersion -eq $version -and -not $Force) {
        Write-Info "Already up to date ($version). Use -Force to reinstall."
        exit 0
    }

    if ($existingVersion) {
        Write-Info "Upgrading $existingVersion -> $version"
    }
}

# ─── Download ──────────────────────────────────────────────────────────
Write-Step "Downloading"

$url = "https://github.com/$Repo/releases/download/$version/$AssetName"
$tempBase = (Get-Item $env:TEMP).FullName
$tempDir  = Join-Path $tempBase "mosaico-install-$PID"
$zipPath  = Join-Path $tempDir $AssetName

New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

try {
    Write-Info "Downloading $AssetName..."
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
    $sizeMB = [Math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    Write-Info "Downloaded $sizeMB MB"
} catch {
    Fail "Download failed: $_"
}

# ─── Extract ───────────────────────────────────────────────────────────
Write-Step "Extracting"

try {
    Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force
    Write-Info "Extracted to $tempDir"
} catch {
    Fail "Extraction failed: $_"
}

# Find the exe — the zip may nest it in a subfolder.
$extractedExe = Get-ChildItem -Path $tempDir -Filter $ExeName -Recurse |
    Select-Object -First 1
if (-not $extractedExe) {
    Fail "Could not find $ExeName in the extracted archive."
}

# ─── Stop Running Daemon ───────────────────────────────────────────────
Write-Step "Preparing installation"

$running = Get-Process -Name "mosaico" -ErrorAction SilentlyContinue
if ($running) {
    Write-Info "Stopping running mosaico daemon..."
    $running | Stop-Process -Force
    Start-Sleep -Milliseconds 500
}

# ─── Install ───────────────────────────────────────────────────────────
Write-Step "Installing"

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Path $extractedExe.FullName -Destination $exePath -Force
Unblock-File -Path $exePath
Write-Info "Installed to $exePath"

# ─── PATH ──────────────────────────────────────────────────────────────
if (-not $NoPath) {
    Write-Step "Updating PATH"

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*$InstallDir*") {
        [Environment]::SetEnvironmentVariable(
            "Path", "$userPath;$InstallDir", "User"
        )
        $env:Path = "$env:Path;$InstallDir"
        Write-Info "Added $InstallDir to user PATH"
    } else {
        Write-Info "Already on PATH"
    }
}

# ─── Verify ────────────────────────────────────────────────────────────
Write-Step "Verifying installation"

try {
    $installedVersion = (& $exePath --version) -replace '^mosaico\s+', ''
    Write-Info "Installed version: $installedVersion"
} catch {
    Fail "Verification failed — the binary did not run: $_"
}

# ─── Config Generation ─────────────────────────────────────────────────
if (-not $NoConfig) {
    Write-Step "Generating config"

    $configFile = Join-Path $ConfigDir "config.toml"
    if (Test-Path $configFile) {
        Write-Info "Config already exists at $ConfigDir — leaving it untouched"
    } else {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        & $exePath init
        Write-Info "Default config written to $ConfigDir"
    }
}

# ─── Autostart ─────────────────────────────────────────────────────────
if (-not $NoAutostart) {
    Write-Step "Enabling autostart"

    try {
        & $exePath autostart enable
        Write-Info "Mosaico will start automatically on boot"
    } catch {
        Write-Warn "Could not enable autostart: $_"
        Write-Warn "Run 'mosaico autostart enable' manually after installation."
    }
}

# ─── Cleanup ───────────────────────────────────────────────────────────
Write-Step "Cleaning up"
Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
Write-Info "Temporary files removed"

# ─── Done ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Installation complete." -ForegroundColor Green
Write-Host ""
Write-Host "  Binary:  $exePath" -ForegroundColor Gray
Write-Host "  Config:  $ConfigDir" -ForegroundColor Gray
Write-Host ""

if ($NoConfig) {
    Write-Host "  Next step: run 'mosaico init' to create config files." -ForegroundColor Yellow
} else {
    Write-Host "  Next step: run 'mosaico start' to launch the window manager." -ForegroundColor Yellow
}
Write-Host ""

if (-not $NoAutostart) {
    Write-Host "  Autostart is enabled. To disable: mosaico autostart disable" -ForegroundColor DarkGray
}
Write-Host ""