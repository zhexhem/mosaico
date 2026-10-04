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
    [string]$InstallDir = "$env:LOCALAPPDATA\mosaico",
    [string]$Version    = "latest",
    [switch]$NoConfig,
    [switch]$NoAutostart,
    [switch]$NoPath,
    [switch]$Force,
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

# Normalize a version string: trim, strip leading 'v'/'V'.
function Get-NormalizedVersion {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    return ($Value.Trim() -replace '^[vV]', '')
}

# Extract a semver-ish token from arbitrary CLI output.
function Get-VersionFromOutput {
    param([string]$Output)
    if ([string]::IsNullOrWhiteSpace($Output)) { return $null }
    if ($Output -match '(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z\.\-]+)?)') {
        return $Matches[1]
    }
    return ($Output.Trim() -replace '^mosaico\s+', '')
}

# Safely read `mosaico --version` without tripping on stderr / ErrorActionPreference.
function Get-InstalledVersion {
    param([string]$ExePath)
    if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath)) { return $null }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $ExePath --version 2>&1 | Out-String
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $prev
    }
    return Get-VersionFromOutput $output
}

# Case-insensitive, trailing-slash-tolerant PATH entry check.
function Test-PathEntry {
    param([string]$PathString, [string]$Entry)
    if ([string]::IsNullOrWhiteSpace($PathString) -or [string]::IsNullOrWhiteSpace($Entry)) {
        return $false
    }
    $target = $Entry.TrimEnd('\')
    foreach ($p in ($PathString -split ';')) {
        if ($p -and $p.TrimEnd('\') -ieq $target) { return $true }
    }
    return $false
}

# Remove an entry from a PATH string, case-insensitive, tolerant of trailing slashes.
function Remove-PathEntry {
    param([string]$PathString, [string]$Entry)
    if ([string]::IsNullOrWhiteSpace($PathString)) { return "" }
    $target = $Entry.TrimEnd('\')
    $kept = foreach ($p in ($PathString -split ';')) {
        if ($p -and $p.TrimEnd('\') -ine $target) { $p }
    }
    return ($kept -join ';')
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
    if (Test-Path -LiteralPath $exePath) {
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
    if (Test-PathEntry -PathString $userPath -Entry $InstallDir) {
        $newPath = Remove-PathEntry -PathString $userPath -Entry $InstallDir
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Info "Removed $InstallDir from user PATH"
    } else {
        Write-Info "Not on PATH"
    }

    Write-Step "Removing binary"
    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -Recurse -Force -LiteralPath $InstallDir
        Write-Info "Removed $InstallDir"
    } else {
        Write-Info "Install directory does not exist"
    }

    Write-Step "Removing config"
    if (Test-Path -LiteralPath $ConfigDir) {
        Remove-Item -Recurse -Force -LiteralPath $ConfigDir
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
    # Normalize to tag form (v-prefixed) so download URLs resolve.
    if ($Version -notmatch '^[vV]') { $Version = "v$Version" }
    Write-Info "Pinned version: $Version"
}

$normalizedNew = Get-NormalizedVersion $Version

# ─── Existing Installation ─────────────────────────────────────────────
Write-Step "Checking existing installation"

$exePath         = Join-Path $InstallDir $ExeName
$existingVersion = Get-InstalledVersion -ExePath $exePath
$skipInstall     = $false

if ($existingVersion) {
    $normalizedExisting = Get-NormalizedVersion $existingVersion
    Write-Info "Existing installation: $existingVersion"

    if ($normalizedExisting -eq $normalizedNew -and -not $Force) {
        Write-Info "Binary already up to date ($Version) — skipping download."
        $skipInstall = $true
    } else {
        Write-Info "Upgrading $existingVersion -> $Version"
    }
} elseif (Test-Path -LiteralPath $InstallDir) {
    Write-Warn "Install directory exists but no binary found at $exePath"
}

# ─── Download / Extract / Install ──────────────────────────────────────
if (-not $skipInstall) {
    Write-Step "Downloading"

    $url      = "https://github.com/$Repo/releases/download/$Version/$AssetName"
    $tempBase = if ($env:TEMP) { (Get-Item -LiteralPath $env:TEMP).FullName } else { [IO.Path]::GetTempPath() }
    $tempDir  = Join-Path $tempBase "mosaico-install-$PID"
    $zipPath  = Join-Path $tempDir $AssetName

    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

    try {
        Write-Info "Downloading $AssetName..."
        Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
        $sizeMB = [Math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)
        Write-Info "Downloaded $sizeMB MB"
    } catch {
        Fail "Download failed: $_"
    }

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

    Write-Step "Preparing installation"
    $running = Get-Process -Name "mosaico" -ErrorAction SilentlyContinue
    if ($running) {
        Write-Info "Stopping running daemon..."
        $running | Stop-Process -Force
        Start-Sleep -Milliseconds 500
    }

    Write-Step "Installing"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item -LiteralPath $extractedExe.FullName -Destination $exePath -Force
    Unblock-File -LiteralPath $exePath
    Write-Info "Installed to $exePath"
} else {
    # Ensure the existing binary is unblocked, in case it was fetched by a browser.
    try { Unblock-File -LiteralPath $exePath -ErrorAction SilentlyContinue } catch { }
}

# ─── PATH ──────────────────────────────────────────────────────────────
if (-not $NoPath) {
    Write-Step "Updating PATH"

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (Test-PathEntry -PathString $userPath -Entry $InstallDir)) {
        $newPath = if ([string]::IsNullOrEmpty($userPath)) {
            $InstallDir
        } else {
            "$userPath;$InstallDir"
        }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        if (-not (Test-PathEntry -PathString $env:Path -Entry $InstallDir)) {
            $env:Path = "$env:Path;$InstallDir"
        }
        Write-Info "Added $InstallDir to user PATH"
    } else {
        Write-Info "Already on PATH"
    }
}

# ─── Verify ────────────────────────────────────────────────────────────
Write-Step "Verifying"

$installedVersion = Get-InstalledVersion -ExePath $exePath
if (-not $installedVersion) {
    Fail "Verification failed — the binary did not run at $exePath"
}
Write-Info "Installed version: $installedVersion"

# ─── Config ────────────────────────────────────────────────────────────
if (-not $NoConfig) {
    Write-Step "Generating config"

    $configFile = Join-Path $ConfigDir "config.toml"
    if (Test-Path -LiteralPath $configFile) {
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
if (-not $skipInstall) {
    Write-Step "Cleaning up"
    if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
        Remove-Item -Recurse -Force -LiteralPath $tempDir -ErrorAction SilentlyContinue
    }
    Write-Info "Temporary files removed"
}

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
Write-Host "  Uninstall with: install.ps1 -Uninstall" -ForegroundColor DarkGray
Write-Host ""