# install.ps1
# ──────────────────────────────────────────────────────────────────────
# Mosaico Tiling Window Manager — Windows Installer
# https://github.com/zhexhem/mosaico
#
# Usage:
#   irm https://raw.githubusercontent.com/zhexhem/mosaico/main/install.ps1 | iex
#
#   .\install.ps1
#   .\install.ps1 -InstallDir "C:\Tools\mosaico" -NoConfig -NoAutostart
#   .\install.ps1 -Uninstall
# ──────────────────────────────────────────────────────────────────────

[CmdletBinding()]
param(
    # Where to install the mosaico.exe binary.
    [string]$InstallDir = "$env:LOCALAPPDATA\mosaico",

    # Version to install. Defaults to the latest GitHub release.
    [string]$Version = "latest",

    # Skip generating default config files.
    [switch]$NoConfig,

    # Skip enabling autostart.
    [switch]$NoAutostart,

    # Skip adding the install directory to the user PATH.
    [switch]$NoPath,

    # Force reinstall even if the same version is already present.
    [switch]$Force,

    # Uninstall Mosaico instead of installing.
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

# ─── Constants ─────────────────────────────────────────────────────────
$Repo      = "zhexhem/mosaico"
$AssetName = "mosaico-windows-amd64.zip"
$ExeName   = "mosaico.exe"
$ConfigDir = if ($env:XDG_CONFIG_HOME) {
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
    Write-Host "-- $Message " -ForegroundColor Cyan -NoNewline
    Write-Host ("-" * [Math]::Max(0, 58 - $Message.Length)) -ForegroundColor DarkGray
}

function Fail {
    param([string]$Message)
    Write-Err $Message
    exit 1
}

# ─── Uninstall Path ────────────────────────────────────────────────────
if ($Uninstall) {
    Write-Host ""
    Write-Host "Mosaico Uninstaller" -ForegroundColor White
    Write-Host "===================" -ForegroundColor DarkGray
    Write-Host ""

    Write-Step "Stopping daemon"
    $running = Get-Process -Name "mosaico" -ErrorAction SilentlyContinue
    if ($running) {
        $running | Stop-Process -Force
        Start-Sleep -Milliseconds 500
        Write-Info "Daemon stopped"
    } else {
        Write-Info "Daemon is not running"
    }

    Write-Step "Disabling autostart"
    $exePath = Join-Path $InstallDir $ExeName
    if (Test-Path $exePath) {
        try {
            & $exePath autostart disable 2>$null | Out-Null
            Write-Info "Autostart disabled"
        } catch {
            Write-Warn "Could not disable autostart via CLI"
        }
    } else {
        Write-Info "No binary found — skipping"
    }

    Write-Step "Removing from PATH"
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -like "*$InstallDir*") {
        $newPath = ($userPath -split ';' |
            Where-Object { $_ -and $_ -ne $InstallDir }) -join ';'
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Info "Removed $InstallDir from user PATH"
    } else {
        Write-Info "Not on PATH"
    }

    Write-Step "Removing binary"
    if (Test-Path $InstallDir) {
        Remove-Item -Recurse -Force $InstallDir
        Write-Info "Removed $InstallDir"
    } else {
        Write-Info "Install directory does not exist"
    }

    Write-Step "Removing config"
    if (Test-Path $ConfigDir) {
        Remove-Item -Recurse -Force $ConfigDir
        Write-Info "Removed $ConfigDir"
    } else {
        Write-Info "Config directory does not exist"
    }

    Write-Host ""
    Write-Host "  Uninstall complete." -ForegroundColor Green
    Write-Host ""
    exit 0
}

# ─── Header ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Mosaico Installer" -ForegroundColor White
Write-Host "=================" -ForegroundColor DarkGray
Write-Host ""

# ─── Prerequisites ─────────────────────────────────────────────────────
Write-Step "Checking prerequisites"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Fail "PowerShell 5.1 or later is required. Detected: $($PSVersionTable.PSVersion)"
}
Write-Info "PowerShell $($PSVersionTable.PSVersion) detected"

$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne "AMD64") {
    Write-Warn "Detected architecture: $arch. Only amd64 builds are published."
    Write-Warn "Continuing anyway — the binary may not run on this system."
} else {
    Write-Info "Architecture: AMD64"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ─── Resolve Release ───────────────────────────────────────────────────
Write-Step "Resolving release"

if ($Version -eq "latest") {
    try {
        $headers = @{ "User-Agent" = "mosaico-installer" }
        $release = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$Repo/releases/latest" `
            -Headers $headers
        $Version = $release.tag_name
        Write-Info "Latest version: $Version"
    } catch {
        Fail "Could not determine latest version. Check https://github.com/$Repo/releases"
    }
} else {
    Write-Info "Pinned version: $Version"
}

# ─── Existing Installation ─────────────────────────────────────────────
$exePath = Join-Path $InstallDir $ExeName
$existingVersion = $null

if (Test-Path $exePath) {
    try {
        $existingVersion = (& $exePath --version 2>$null) -replace '^mosaico\s+', ''
        Write-Info "Existing installation: $existingVersion"
    } catch {
        Write-Warn "Existing binary found but could not read version"
    }

    if ($existingVersion -eq $Version -and -not $Force) {
        Write-Info "Already up to date ($Version). Use -Force to reinstall."
        exit 0
    }

    if ($existingVersion) {
        Write-Info "Upgrading $existingVersion -> $Version"
    }
}

# ─── Download ──────────────────────────────────────────────────────────
Write-Step "Downloading"

$url      = "https://github.com/$Repo/releases/download/$Version/$AssetName"
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

$extractedExe = Get-ChildItem -Path $tempDir -Filter $ExeName -Recurse |
    Select-Object -First 1
if (-not $extractedExe) {
    Fail "Could not find $ExeName in the extracted archive."
}

# ─── Stop Running Daemon ───────────────────────────────────────────────
Write-Step "Preparing installation"

$running = Get-Process -Name "mosaico" -ErrorAction SilentlyContinue
if ($running) {
    Write-Info "Stopping running daemon..."
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
Write-Step "Verifying"

try {
    $installedVersion = (& $exePath --version) -replace '^mosaico\s+', ''
    Write-Info "Installed version: $installedVersion"
} catch {
    Fail "Verification failed — the binary did not run: $_"
}

# ─── Config ────────────────────────────────────────────────────────────
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
        Write-Warn "Run 'mosaico autostart enable' manually."
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
Write-Host "  Version: $installedVersion" -ForegroundColor Gray
Write-Host ""

if ($NoConfig) {
    Write-Host "  Next: run 'mosaico init' to create config files." -ForegroundColor Yellow
} else {
    Write-Host "  Next: run 'mosaico start' to launch the window manager." -ForegroundColor Yellow
}
Write-Host ""

if (-not $NoAutostart) {
    Write-Host "  Autostart enabled. Disable with: mosaico autostart disable" -ForegroundColor DarkGray
}
Write-Host "  Uninstall with: .\install.ps1 -Uninstall" -ForegroundColor DarkGray
Write-Host ""