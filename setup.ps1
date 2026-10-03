# setup.ps1
# ──────────────────────────────────────────────────────────────────────
# Mosaico Tiling Window Manager — Complete Setup
# https://github.com/zhexhem/mosaico
#
# Usage:
#   .\setup.ps1                          # Full setup (install + config + profile)
#   .\setup.ps1 -FromSource              # Build from source instead of downloading
#   .\setup.ps1 -SkipInstall             # Skip install, only config + profile
#   .\setup.ps1 -SkipProfile             # Skip PowerShell profile wiring
#   .\setup.ps1 -SkipConfig              # Skip config generation
#   .\setup.ps1 -Minimal                 # Binary only, no config, no profile, no autostart
#   .\setup.ps1 -DryRun                  # Show what would happen without doing it
# ──────────────────────────────────────────────────────────────────────

[CmdletBinding()]
param(
    # Install location for the mosaico.exe binary.
    [string]$InstallDir = "$env:LOCALAPPDATA\mosaico",

    # Build from source instead of downloading a release.
    [switch]$FromSource,

    # Where to clone the repo when building from source.
    [string]$SourceDir = "$env:USERPROFILE\.mosaico-src",

    # Skip the install step (assumes mosaico is already installed).
    [switch]$SkipInstall,

    # Skip generating default config files.
    [switch]$SkipConfig,

    # Skip wiring the PowerShell profile.
    [switch]$SkipProfile,

    # Skip enabling autostart.
    [switch]$SkipAutostart,

    # Minimal mode: binary only, no config, no profile, no autostart.
    [switch]$Minimal,

    # Show what would happen without making any changes.
    [switch]$DryRun,

    # Overwrite existing config files (default: leave them untouched).
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ─── Apply Minimal Preset ──────────────────────────────────────────────
if ($Minimal) {
    $SkipConfig    = $true
    $SkipProfile   = $true
    $SkipAutostart = $true
}

# ─── Constants ─────────────────────────────────────────────────────────
$Repo       = "zhexhem/mosaico"
$ExeName    = "mosaico.exe"
$ConfigDir  = if ($env:XDG_CONFIG_HOME) {
    Join-Path $env:XDG_CONFIG_HOME "mosaico"
} else {
    Join-Path $env:USERPROFILE ".config\mosaico"
}
$ProfileScript = Join-Path $ConfigDir "profile.ps1"

# ─── Helpers ───────────────────────────────────────────────────────────
function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "── $Message " -ForegroundColor Cyan -NoNewline
    Write-Host ("─" * [Math]::Max(0, 56 - $Message.Length)) -ForegroundColor DarkGray
}

function Write-Info {
    param([string]$Message)
    Write-Host "   ✓ " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Warn {
    param([string]$Message)
    Write-Host "   ! " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-Err {
    param([string]$Message)
    Write-Host "   ✗ " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Write-Skip {
    param([string]$Message)
    Write-Host "   › " -ForegroundColor DarkGray -NoNewline
    Write-Host $Message -ForegroundColor DarkGray
}

function Invoke-Or-Dry {
    param(
        [string]$Description,
        [scriptblock]$Action
    )
    if ($DryRun) {
        Write-Host "   ~ [dry-run] $Description" -ForegroundColor Magenta
        return
    }
    & $Action
}

function Fail {
    param([string]$Message)
    Write-Host ""
    Write-Err $Message
    Write-Host ""
    exit 1
}

# ─── Banner ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║                                                  ║" -ForegroundColor Cyan
Write-Host "  ║   Mosaico — Tiling Window Manager Setup          ║" -ForegroundColor Cyan
Write-Host "  ║   https://github.com/$Repo" -ForegroundColor Cyan -NoNewline
Write-Host (" " * (34 - $Repo.Length)) -NoNewline
Write-Host "║" -ForegroundColor Cyan
Write-Host "  ║                                                  ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan

if ($DryRun) {
    Write-Host ""
    Write-Host "  DRY RUN — no changes will be made." -ForegroundColor Magenta
}

# ─── Step 1: Prerequisites ─────────────────────────────────────────────
Write-Step "1/7  Prerequisites"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Fail "PowerShell 5.1+ required. Detected: $($PSVersionTable.PSVersion)"
}
Write-Info "PowerShell $($PSVersionTable.PSVersion)"

$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne "AMD64") {
    Write-Warn "Architecture is $arch — only amd64 builds published"
} else {
    Write-Info "Architecture AMD64"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($FromSource) {
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if (-not $cargo) {
        Fail "Rust toolchain (cargo) required for -FromSource. Install from https://rustup.rs"
    }
    Write-Info "Rust toolchain: $(cargo --version)"
}

# Check for conflicting tiling managers
$conflicts = @()
foreach ($name in @("komorebi", "glazewm", "fancywm")) {
    if (Get-Process -Name $name -ErrorAction SilentlyContinue) {
        $conflicts += $name
    }
}
if ($conflicts.Count -gt 0) {
    Write-Warn "Another tiling WM is running: $($conflicts -join ', ')"
    Write-Warn "Stop it before starting Mosaico to avoid conflicts."
}

# ─── Step 2: Install Binary ────────────────────────────────────────────
Write-Step "2/7  Install binary"

$exePath = Join-Path $InstallDir $ExeName

if ($SkipInstall) {
    Write-Skip "Skipped (--SkipInstall)"
    if (-not (Test-Path $exePath)) {
        $cmd = Get-Command mosaico -ErrorAction SilentlyContinue
        if (-not $cmd) {
            Fail "mosaico not found on PATH. Cannot skip install."
        }
        $exePath = $cmd.Source
        $InstallDir = Split-Path $exePath -Parent
        Write-Info "Using existing: $exePath"
    }
} elseif ($FromSource) {
    # ── Build from source ──
    if (Test-Path (Join-Path $SourceDir ".git")) {
        Write-Info "Updating existing source at $SourceDir"
        Invoke-Or-Dry "git -C $SourceDir pull --ff-only" {
            git -C $SourceDir pull --ff-only | Out-Null
        }
    } else {
        Write-Info "Cloning into $SourceDir"
        Invoke-Or-Dry "git clone https://github.com/$Repo $SourceDir" {
            git clone "https://github.com/$Repo" $SourceDir | Out-Null
        }
    }

    Write-Info "Building (this may take a few minutes)..."
    Invoke-Or-Dry "cargo build --release" {
        Push-Location $SourceDir
        try {
            cargo build --release
        } finally {
            Pop-Location
        }
    }

    $built = Join-Path $SourceDir "target\release\$ExeName"
    if (-not $DryRun -and -not (Test-Path $built)) {
        Fail "Build succeeded but $built not found"
    }

    Invoke-Or-Dry "Install $built -> $exePath" {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        Copy-Item -Path $built -Destination $exePath -Force
        Unblock-File -Path $exePath
    }
    Write-Info "Installed from source to $exePath"
} else {
    # ── Download release ──
    $existingVersion = $null
    if (Test-Path $exePath) {
        try {
            $existingVersion = (& $exePath --version 2>$null) -replace '^mosaico\s+', ''
        } catch { }
    }

    if ($existingVersion -and -not $Force) {
        Write-Info "Already installed: $existingVersion (use -Force to reinstall)"
    } else {
        # Stop daemon before replacing
        $running = Get-Process -Name "mosaico" -ErrorAction SilentlyContinue
        if ($running) {
            Write-Info "Stopping running daemon"
            Invoke-Or-Dry "Stop-Process" { $running | Stop-Process -Force }
            Start-Sleep -Milliseconds 500
        }

        Write-Info "Downloading latest release..."
        Invoke-Or-Dry "Download and extract release" {
            $headers = @{ "User-Agent" = "mosaico-setup" }
            $release = Invoke-RestMethod `
                -Uri "https://api.github.com/repos/$Repo/releases/latest" `
                -Headers $headers
            $tag = $release.tag_name

            $tempDir = Join-Path $env:TEMP "mosaico-setup-$PID"
            New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

            try {
                $zip = Join-Path $tempDir "mosaico.zip"
                $url = "https://github.com/$Repo/releases/download/$tag/mosaico-windows-amd64.zip"
                Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
                Expand-Archive -Path $zip -DestinationPath $tempDir -Force

                $found = Get-ChildItem -Path $tempDir -Filter $ExeName -Recurse |
                    Select-Object -First 1
                if (-not $found) {
                    throw "Could not find $ExeName in archive"
                }

                New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
                Copy-Item -Path $found.FullName -Destination $exePath -Force
                Unblock-File -Path $exePath

                Write-Host "     Installed version: $tag" -ForegroundColor Gray
            } finally {
                Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            }
        }
    }
}

# ─── Step 3: PATH ──────────────────────────────────────────────────────
Write-Step "3/7  Update PATH"

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$InstallDir*") {
    Invoke-Or-Dry "Add $InstallDir to user PATH" {
        [Environment]::SetEnvironmentVariable(
            "Path", "$userPath;$InstallDir", "User"
        )
    }
    $env:Path = "$env:Path;$InstallDir"
    Write-Info "Added to PATH"
} else {
    Write-Info "Already on PATH"
}

# ─── Step 4: Config ────────────────────────────────────────────────────
Write-Step "4/7  Generate config"

if ($SkipConfig) {
    Write-Skip "Skipped (-SkipConfig)"
} else {
    $configFile = Join-Path $ConfigDir "config.toml"
    $configExists = Test-Path $configFile

    if ($configExists -and -not $Force) {
        Write-Info "Config exists at $ConfigDir (use -Force to overwrite)"
    } else {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

        Invoke-Or-Dry "Run 'mosaico init'" {
            & $exePath init | Out-Null
        }
        Write-Info "Wrote default config to $ConfigDir"

        # Verify all expected files
        $expected = @("config.toml", "keybindings.toml", "bar.toml", "user-rules.toml")
        foreach ($f in $expected) {
            $p = Join-Path $ConfigDir $f
            if (Test-Path $p) {
                Write-Host "     · $f" -ForegroundColor DarkGray
            }
        }
    }
}

# ─── Step 5: PowerShell Profile ────────────────────────────────────────
Write-Step "5/7  PowerShell profile"

if ($SkipProfile) {
    Write-Skip "Skipped (-SkipProfile)"
} else {
    # Write the profile extension to the config dir
    Invoke-Or-Dry "Write $ProfileScript" {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

        $profileBody = @'
# ──────────────────────────────────────────────────────────────────────
# Mosaico PowerShell Profile — auto-generated by setup.ps1
# ──────────────────────────────────────────────────────────────────────

$MosaicoExe = Join-Path $env:LOCALAPPDATA "mosaico\mosaico.exe"
if (-not (Test-Path $MosaicoExe)) {
    $MosaicoCmd = Get-Command mosaico -ErrorAction SilentlyContinue
    if (-not $MosaicoCmd) { return }
} else {
    $mosaicoDir = Split-Path $MosaicoExe -Parent
    if ($env:Path -notlike "*$mosaicoDir*") {
        $env:Path = "$env:Path;$mosaicoDir"
    }
}

# Tab completion for `mosaico`
$MosaicoCompleter = {
    param($wordToComplete, $commandAst, $cursorPosition)
    $commands = @('start','stop','status','doctor','init','pause','unpause',
        'restart','action','debug','autostart','config','--help','--version')
    $actions  = @('focus','move','retile','toggle-monocle','cycle-layout',
        'close-focused','minimize-focused',
        'goto-workspace-1','goto-workspace-2','goto-workspace-3','goto-workspace-4',
        'goto-workspace-5','goto-workspace-6','goto-workspace-7','goto-workspace-8',
        'send-to-workspace-1','send-to-workspace-2','send-to-workspace-3','send-to-workspace-4',
        'send-to-workspace-5','send-to-workspace-6','send-to-workspace-7','send-to-workspace-8')
    $directions = @('left','right','up','down')
    $debugSubs  = @('list','events')
    $autostartSubs = @('enable','disable','status')

    $tokens = $commandAst.CommandElements | ForEach-Object { $_.Value }
    $prev = if ($tokens.Count -ge 2) { $tokens[$tokens.Count - 2] } else { $null }

    $candidates = switch ($prev) {
        'action'    { $actions }
        'debug'     { $debugSubs }
        'autostart' { $autostartSubs }
        'focus'     { $directions }
        'move'      { $directions }
        default {
            if ($tokens.Count -le 2) { $commands } else { @() }
        }
    }

    $candidates | Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new(
                $_, $_, 'ParameterValue', $_)
        }
}
Register-ArgumentCompleter -Native -CommandName mosaico -ScriptBlock $MosaicoCompleter

# Helper functions
function Start-Tiling    { mosaico start }
function Stop-Tiling     { mosaico stop }
function Restart-Tiling  { mosaico stop; Start-Sleep -Milliseconds 300; mosaico start }
function Get-TilingStatus {
    $proc = Get-Process -Name mosaico -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Host "● Mosaico running (PID $($proc.Id))" -ForegroundColor Green
    } else {
        Write-Host "○ Mosaico stopped" -ForegroundColor Red
    }
}
function Switch-TilingLayout { mosaico action cycle-layout }
function Invoke-TilingMonocle { mosaico action toggle-monocle }
function Switch-Workspace {
    param([Parameter(Mandatory)][ValidateRange(1,8)][int]$Number)
    mosaico action "goto-workspace-$Number"
}
function Send-ToWorkspace {
    param([Parameter(Mandatory)][ValidateRange(1,8)][int]$Number)
    mosaico action "send-to-workspace-$Number"
}
function Get-TilingConfig {
    $dir = if ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME "mosaico" }
           else { Join-Path $env:USERPROFILE ".config\mosaico" }
    if (Test-Path $dir) { Invoke-Item $dir }
    else { Write-Warning "Config dir not found: $dir" }
}
function Edit-TilingConfig {
    param([ValidateSet('config','keybindings','bar','rules','user-rules')][string]$File='config')
    $dir = if ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME "mosaico" }
           else { Join-Path $env:USERPROFILE ".config\mosaico" }
    $path = Join-Path $dir "$File.toml"
    if (Test-Path $path) { Invoke-Item $path }
    else { Write-Warning "Not found: $path" }
}
function Get-TilingDoctor  { mosaico doctor }
function Get-TilingWindows { mosaico debug list }

Set-Alias ms        mosaico
Set-Alias mtstart   Start-Tiling
Set-Alias mtstop    Stop-Tiling
Set-Alias mtrestart Restart-Tiling
Set-Alias mtstatus  Get-TilingStatus
Set-Alias mtlayout  Switch-TilingLayout
Set-Alias mtmonocle Invoke-TilingMonocle
Set-Alias mtws      Switch-Workspace
Set-Alias mtconfig  Get-TilingConfig
Set-Alias mtconfige Edit-TilingConfig
Set-Alias mthealth  Get-TilingDoctor
Set-Alias mtwindows Get-TilingWindows

# Prompt indicator
$MosaicoBasePrompt = $function:prompt
function global:prompt {
    $proc = Get-Process -Name mosaico -ErrorAction SilentlyContinue
    $indicator = if ($proc) { "`e[36m◆`e[0m " } else { "`e[90m◇`e[0m " }
    "$indicator" + (& $MosaicoBasePrompt)
}
'@

        Set-Content -Path $ProfileScript -Value $profileBody -Encoding UTF8
    }
    Write-Info "Wrote profile extension: $ProfileScript"

    # Wire it into $PROFILE
    $sourceLine = ". `"$ProfileScript`""
    $profilePath = $PROFILE.CurrentUserAllHosts

    $profileExists = Test-Path $profilePath
    if (-not $profileExists) {
        Invoke-Or-Dry "Create $profilePath" {
            New-Item -ItemType File -Path $profilePath -Force | Out-Null
        }
    }

    $profileContent = if ($profileExists) {
        Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
    } else { "" }

    if ($profileContent -and $profileContent.Contains($sourceLine)) {
        Write-Info "Already sourced from `$PROFILE"
    } else {
        Invoke-Or-Dry "Add source line to `$PROFILE" {
            $comment = "# Mosaico tiling window manager helpers"
            Add-Content -Path $profilePath -Value "`n$comment`n$sourceLine"
        }
        Write-Info "Added source line to $profilePath"
    }
}

# ─── Step 6: Autostart ─────────────────────────────────────────────────
Write-Step "6/7  Autostart"

if ($SkipAutostart) {
    Write-Skip "Skipped (-SkipAutostart)"
} else {
    Invoke-Or-Dry "Enable autostart" {
        & $exePath autostart enable | Out-Null
    }
    Write-Info "Mosaico will start on login"
    Write-Host "     Disable with: mosaico autostart disable" -ForegroundColor DarkGray
}

# ─── Step 7: Verify ────────────────────────────────────────────────────
Write-Step "7/7  Verify"

if ($DryRun) {
    Write-Host "   ~ [dry-run] Would run: mosaico doctor" -ForegroundColor Magenta
} else {
    $version = & $exePath --version 2>$null
    Write-Info "Binary: $version"

    $files = @("config.toml","keybindings.toml","bar.toml","user-rules.toml")
    $missing = $files | Where-Object { -not (Test-Path (Join-Path $ConfigDir $_)) }
    if ($missing.Count -eq 0 -and -not $SkipConfig) {
        Write-Info "Config: all 4 files present"
    } elseif (-not $SkipConfig) {
        Write-Warn "Missing config files: $($missing -join ', ')"
    }

    if (-not $SkipProfile) {
        $wired = (Get-Content $PROFILE.CurrentUserAllHosts -Raw -ErrorAction SilentlyContinue) `
            -like "*$ProfileScript*"
        if ($wired) { Write-Info "Profile: wired into `$PROFILE" }
        else { Write-Warn "Profile: source line not found in `$PROFILE" }
    }

    if (-not $SkipAutostart) {
        try {
            $auto = & $exePath autostart status 2>$null
            Write-Info "Autostart: $auto"
        } catch { }
    }
}

# ─── Done ──────────────────────────────────────────────────────────────
Write-Host ""
if ($DryRun) {
    Write-Host "  Dry run complete. Re-run without -DryRun to apply." -ForegroundColor Magenta
    Write-Host ""
    exit 0
}

Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║                 Setup complete                   ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

Write-Host "  Binary:   $exePath" -ForegroundColor Gray
Write-Host "  Config:   $ConfigDir" -ForegroundColor Gray
if (-not $SkipProfile) {
    Write-Host "  Profile:  $ProfileScript" -ForegroundColor Gray
}
Write-Host ""

Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "    1. Reload your profile:  " -NoNewline -ForegroundColor Gray
Write-Host ". `$PROFILE" -ForegroundColor White
Write-Host "    2. Start the daemon:     " -NoNewline -ForegroundColor Gray
Write-Host "mosaico start" -ForegroundColor White
Write-Host "    3. Check status:         " -NoNewline -ForegroundColor Gray
Write-Host "mtstatus" -ForegroundColor White
Write-Host ""
Write-Host "  Default keys:  Alt+H/J/K/L focus  ·  Alt+Shift+H/J/K/L move  ·  Alt+1-8 workspaces" -ForegroundColor DarkGray
Write-Host "  Full reference: https://github.com/$Repo" -ForegroundColor DarkGray
Write-Host ""