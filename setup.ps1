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
#   .\setup.ps1 -Version v0.3.0          # Pin a specific release tag
#   .\setup.ps1 -Force                   # Overwrite existing config + reinstall binary
# ──────────────────────────────────────────────────────────────────────

[CmdletBinding()]
param(
    [string]$InstallDir    = "$env:LOCALAPPDATA\mosaico",
    [switch]$FromSource,
    [string]$SourceDir     = "$env:USERPROFILE\.mosaico-src",
    [string]$Version,
    [switch]$SkipInstall,
    [switch]$SkipConfig,
    [switch]$SkipProfile,
    [switch]$SkipAutostart,
    [switch]$Minimal,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ─── Apply Minimal Preset ──────────────────────────────────────────────
if ($Minimal) {
    $SkipConfig    = $true
    $SkipProfile   = $true
    $SkipAutostart = $true
}

# ─── Constants ─────────────────────────────────────────────────────────
$Repo          = "zhexhem/mosaico"
$ExeName       = "mosaico.exe"
$ConfigDir     = if ($env:XDG_CONFIG_HOME) {
    Join-Path $env:XDG_CONFIG_HOME "mosaico"
} else {
    Join-Path $env:USERPROFILE ".config\mosaico"
}
$ProfileScript = Join-Path $ConfigDir "profile.ps1"
$IsPS7Plus     = $PSVersionTable.PSVersion.Major -ge 7
$BannerWidth   = 56

# ─── Helpers ───────────────────────────────────────────────────────────
function Write-Step {
    param([string]$Message)
    $prefix = "── $Message "
    $fill   = [Math]::Max(0, $BannerWidth - $prefix.Length)
    Write-Host ""
    Write-Host $prefix -ForegroundColor Cyan -NoNewline
    Write-Host ("─" * $fill) -ForegroundColor DarkGray
}

function Write-Info { param([string]$Message) Write-Host "   ✓ " -ForegroundColor Green    -NoNewline; Write-Host $Message }
function Write-Warn { param([string]$Message) Write-Host "   ! " -ForegroundColor Yellow   -NoNewline; Write-Host $Message }
function Write-Err  { param([string]$Message) Write-Host "   ✗ " -ForegroundColor Red      -NoNewline; Write-Host $Message }
function Write-Skip { param([string]$Message) Write-Host "   › " -ForegroundColor DarkGray -NoNewline; Write-Host $Message -ForegroundColor DarkGray }

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

# Return $true if $Dir (normalized) is present on User, Machine, or session PATH.
function Test-DirOnPath {
    param([string]$Dir)
    $canonical = $Dir.TrimEnd('\', '/')
    $sources = @(
        [Environment]::GetEnvironmentVariable("Path", "User")
        [Environment]::GetEnvironmentVariable("Path", "Machine")
        $env:Path
    )
    foreach ($p in $sources) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        foreach ($entry in $p -split ';') {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            if ($entry.TrimEnd('\', '/') -ieq $canonical) { return $true }
        }
    }
    return $false
}

function Add-DirToUserPath {
    param([string]$Dir)
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $newPath  = if ([string]::IsNullOrWhiteSpace($userPath)) { $Dir } else { "$userPath;$Dir" }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
}

function Ensure-DirOnSessionPath {
    param([string]$Dir)
    if (Test-DirOnPath -Dir $Dir) { return }
    $env:Path = "$env:Path;$Dir"
}

function Invoke-WebRequestCompat {
    param([string]$Uri, [string]$OutFile)
    $params = @{ Uri = $Uri; OutFile = $OutFile }
    if (-not $IsPS7Plus) { $params.UseBasicParsing = $true }
    Invoke-WebRequest @params
}

function Invoke-RestMethodCompat {
    param([string]$Uri, [hashtable]$Headers)
    $params = @{ Uri = $Uri; Headers = $Headers }
    if (-not $IsPS7Plus) { $params.UseBasicParsing = $true }
    Invoke-RestMethod @params
}

function Stop-MosaicoDaemon {
    param([string]$ProcessName = "mosaico")
    $procs = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return }
    Write-Info "Stopping running daemon (PID $($procs[0].Id))"
    if ($DryRun) { return }
    foreach ($p in $procs) { try { $p | Stop-Process -Force -ErrorAction SilentlyContinue } catch { } }
    # Wait up to 5s for exit instead of a fixed sleep.
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -eq 0) { return }
        Start-Sleep -Milliseconds 100
    }
    Write-Warn "Daemon did not exit within 5s; continuing anyway."
}

# Invoke mosaico.exe with the config dir (if the binary supports it), otherwise plain.
function Invoke-Mosaico {
    param(
        [string]$ExePath,
        [string[]]$Arguments,
        [switch]$PassThru
    )
    $finalArgs = @()
    if ($ConfigDir) { $finalArgs += @("--config-dir", $ConfigDir) }
    $finalArgs += $Arguments
    if ($PassThru) {
        & $ExePath @finalArgs
    } else {
        & $ExePath @finalArgs | Out-Null
    }
}

# ─── Banner ────────────────────────────────────────────────────────────
$title  = "   Mosaico — Tiling Window Manager Setup"
$url    = "   https://github.com/$Repo"
$maxLen = [Math]::Max($title.Length, $url.Length)
$inner  = [Math]::Max($BannerWidth, $maxLen)

$top    = "  ╔" + ("═" * $inner) + "╗"
$blank  = "  ║" + (" " * $inner) + "║"
$titleL = "  ║" + $title + (" " * ($inner - $title.Length)) + "║"
$urlL   = "  ║" + $url   + (" " * ($inner - $url.Length))   + "║"
$bottom = "  ╚" + ("═" * $inner) + "╝"

Write-Host ""
Write-Host $top    -ForegroundColor Cyan
Write-Host $blank  -ForegroundColor Cyan
Write-Host $titleL -ForegroundColor Cyan
Write-Host $urlL   -ForegroundColor Cyan
Write-Host $blank  -ForegroundColor Cyan
Write-Host $bottom -ForegroundColor Cyan

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

if (-not $IsPS7Plus) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

if ($FromSource) {
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if (-not $cargo) { Fail "Rust toolchain (cargo) required for -FromSource. Install from https://rustup.rs" }
    Write-Info "Rust toolchain: $((& cargo --version) -replace '^cargo\s+','')"

    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { Fail "git is required for -FromSource." }
}

$conflicts = @()
foreach ($name in @("komorebi", "glazewm", "fancywm")) {
    if (Get-Process -Name $name -ErrorAction SilentlyContinue) { $conflicts += $name }
}
if ($conflicts.Count -gt 0) {
    Write-Warn "Another tiling WM is running: $($conflicts -join ', ')"
    Write-Warn "Stop it before starting Mosaico to avoid conflicts."
}

# ─── Step 2: Install Binary ────────────────────────────────────────────
Write-Step "2/7  Install binary"

$exePath = Join-Path $InstallDir $ExeName

if ($SkipInstall) {
    Write-Skip "Skipped (-SkipInstall)"
    if (-not (Test-Path $exePath)) {
        $cmd = Get-Command mosaico -ErrorAction SilentlyContinue
        if (-not $cmd) { Fail "mosaico not found on PATH. Cannot skip install." }
        $exePath    = $cmd.Source
        $InstallDir = Split-Path $exePath -Parent
    }
    Write-Info "Using existing: $exePath"
} elseif ($FromSource) {
    if (Test-Path (Join-Path $SourceDir ".git")) {
        Write-Info "Updating existing source at $SourceDir"
        Invoke-Or-Dry "git -C `"$SourceDir`" pull --ff-only" {
            git -C $SourceDir pull --ff-only | Out-Null
        }
    } else {
        Write-Info "Cloning into $SourceDir"
        Invoke-Or-Dry "git clone https://github.com/$Repo `"$SourceDir`"" {
            git clone "https://github.com/$Repo" $SourceDir | Out-Null
        }
    }

    Write-Info "Building (this may take a few minutes)..."
    Invoke-Or-Dry "cargo build --release" {
        Push-Location $SourceDir
        try { & cargo build --release } finally { Pop-Location }
    }

    $built = Join-Path $SourceDir "target\release\$ExeName"
    if (-not $DryRun -and -not (Test-Path $built)) {
        Fail "Build succeeded but $built not found"
    }

    if (-not $DryRun) {
        Stop-MosaicoDaemon
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        Copy-Item -Path $built -Destination $exePath -Force
        Unblock-File -Path $exePath
        Write-Info "Installed from source to $exePath"
    } else {
        Write-Host "   ~ [dry-run] Install $built -> $exePath" -ForegroundColor Magenta
    }
} else {
    $existingVersion = $null
    if (Test-Path $exePath) {
        try {
            $existingVersion = ((& $exePath --version 2>$null) -replace '^mosaico\s+', '').Trim()
        } catch { }
    }

    if ($existingVersion -and -not $Force -and -not $Version) {
        Write-Info "Already installed: $existingVersion (use -Force to reinstall)"
    } else {
        Stop-MosaicoDaemon

        Write-Info "Downloading release..."
        Invoke-Or-Dry "Download and extract release" {
            $headers = @{ "User-Agent" = "mosaico-setup" }

            $apiPath = if ($Version) { "tags/$Version" } else { "latest" }
            $apiUri  = "https://api.github.com/repos/$Repo/releases/$apiPath"

            $release = Invoke-RestMethodCompat -Uri $apiUri -Headers $headers
            $tag     = $release.tag_name

            $tempDir = Join-Path $env:TEMP "mosaico-setup-$PID"
            New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
            try {
                $zip = Join-Path $tempDir "mosaico.zip"
                $url = "https://github.com/$Repo/releases/download/$tag/mosaico-windows-amd64.zip"
                Invoke-WebRequestCompat -Uri $url -OutFile $zip
                Expand-Archive -Path $zip -DestinationPath $tempDir -Force

                $found = Get-ChildItem -Path $tempDir -Filter $ExeName -Recurse |
                    Select-Object -First 1
                if (-not $found) { throw "Could not find $ExeName in archive" }

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

if (Test-DirOnPath -Dir $InstallDir) {
    Write-Info "Already on PATH"
} else {
    Invoke-Or-Dry "Add $InstallDir to user PATH" { Add-DirToUserPath -Dir $InstallDir }
    if (-not $DryRun) {
        Ensure-DirOnSessionPath -Dir $InstallDir
        Write-Info "Added to PATH"
    } else {
        Write-Info "Would add to PATH"
    }
}

# ─── Step 4: Config ────────────────────────────────────────────────────
Write-Step "4/7  Generate config"

if ($SkipConfig) {
    Write-Skip "Skipped (-SkipConfig)"
} else {
    $configFile   = Join-Path $ConfigDir "config.toml"
    $configExists = Test-Path $configFile

    if ($configExists -and -not $Force) {
        Write-Info "Config exists at $ConfigDir (use -Force to overwrite)"
    } else {
        if ($configExists -and $Force) {
            Write-Warn "Overwriting existing config at $ConfigDir"
            Invoke-Or-Dry "Remove existing config TOMLs" {
                Remove-Item -Path (Join-Path $ConfigDir "*.toml") -Force -ErrorAction SilentlyContinue
            }
        }

        Invoke-Or-Dry "Create $ConfigDir" {
            New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        }

        Invoke-Or-Dry "Run 'mosaico init'" {
            Invoke-Mosaico -ExePath $exePath -Arguments @("init")
        }

        if (-not $DryRun) {
            Write-Info "Wrote default config to $ConfigDir"
            foreach ($f in @("config.toml", "keybindings.toml", "bar.toml", "user-rules.toml")) {
                if (Test-Path (Join-Path $ConfigDir $f)) {
                    Write-Host "     · $f" -ForegroundColor DarkGray
                }
            }
        }
    }
}

# ─── Step 5: PowerShell Profile ────────────────────────────────────────
Write-Step "5/7  PowerShell profile"

if ($SkipProfile) {
    Write-Skip "Skipped (-SkipProfile)"
} else {
    # -------- 5a. Write the profile extension file --------
    Invoke-Or-Dry "Write $ProfileScript" {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

        # NOTE: single-quoted here-string → contents are literal until sourced.
        #       Do NOT use `e (PS7-only); use [char]27 for 5.1 compatibility.
        $profileBody = @'
# ──────────────────────────────────────────────────────────────────────
# Mosaico PowerShell Profile — auto-generated by setup.ps1
# ──────────────────────────────────────────────────────────────────────

# Guard against double-loading
if ($global:MosaicoProfileLoaded) { return }
$global:MosaicoProfileLoaded = $true

$MosaicoExe = Join-Path $env:LOCALAPPDATA "mosaico\mosaico.exe"
if (-not (Test-Path $MosaicoExe)) {
    $MosaicoCmd = Get-Command mosaico -ErrorAction SilentlyContinue
    if (-not $MosaicoCmd) {
        Write-Verbose "Mosaico not found; skipping profile setup."
        return
    }
} else {
    $mosaicoDir = Split-Path $MosaicoExe -Parent
    $onPath = $false
    foreach ($entry in ($env:Path -split ';')) {
        if ($entry.TrimEnd('\','/') -ieq $mosaicoDir.TrimEnd('\','/')) { $onPath = $true; break }
    }
    if (-not $onPath) { $env:Path = "$env:Path;$mosaicoDir" }
}

# ─── Tab completion for `mosaico` ───
if ($PSVersionTable.PSVersion.Major -ge 7 -and
    -not (Get-Command Register-ArgumentCompleter -ErrorAction SilentlyContinue |
          Where-Object { $_.Parameters.ContainsKey('Native') })) {
    # Older hosts without -Native support; skip.
} elseif ($PSVersionTable.PSVersion.Major -ge 7) {
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
        $directions    = @('left','right','up','down')
        $debugSubs     = @('list','events')
        $autostartSubs = @('enable','disable','status')
        $configSubs    = @('edit','show','path')

        $tokens = @($commandAst.CommandElements | ForEach-Object { $_.Value })
        $prev   = if ($tokens.Count -ge 2) { $tokens[$tokens.Count - 2] } else { $null }

        $candidates = switch ($prev) {
            'action'    { $actions }
            'debug'     { $debugSubs }
            'autostart' { $autostartSubs }
            'config'    { $configSubs }
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
}

# ─── Helper functions ───
function Start-Tiling    { mosaico start }
function Stop-Tiling     { mosaico stop }
function Restart-Tiling  { mosaico stop; Start-Sleep -Milliseconds 300; mosaico start }
function Get-TilingStatus {
    $proc = @(Get-Process -Name mosaico -ErrorAction SilentlyContinue)
    if ($proc.Count -gt 0) {
        Write-Host "● Mosaico running (PID $($proc[0].Id))" -ForegroundColor Green
    } else {
        Write-Host "○ Mosaico stopped" -ForegroundColor Red
    }
}
function Switch-TilingLayout  { mosaico action cycle-layout }
function Invoke-TilingMonocle { mosaico action toggle-monocle }

function Switch-Workspace {
    param([Parameter(Mandatory)][ValidateRange(1,8)][int]$Number)
    mosaico action "goto-workspace-$Number"
}
function Send-ToWorkspace {
    param([Parameter(Mandatory)][ValidateRange(1,8)][int]$Number)
    mosaico action "send-to-workspace-$Number"
}

function Get-MosaicoConfigDir {
    if ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME "mosaico" }
    else { Join-Path $env:USERPROFILE ".config\mosaico" }
}
function Get-TilingConfig {
    $dir = Get-MosaicoConfigDir
    if (Test-Path $dir) { Invoke-Item $dir }
    else { Write-Warning "Config dir not found: $dir" }
}
function Edit-TilingConfig {
    param([ValidateSet('config','keybindings','bar','rules','user-rules')][string]$File='config')
    $dir  = Get-MosaicoConfigDir
    $path = Join-Path $dir "$File.toml"
    if (Test-Path $path) { Invoke-Item $path }
    else { Write-Warning "Not found: $path" }
}
function Get-TilingDoctor  { mosaico doctor }
function Get-TilingWindows { mosaico debug list }

# ─── Aliases ───
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

# ─── Prompt indicator (safe re-entrancy) ───
# Uses [char]27 rather than `e so Windows PowerShell 5.1 renders correctly.
if (-not $global:MosaicoBasePrompt) {
    $global:MosaicoBasePrompt = $function:prompt
}
function global:prompt {
    $proc = Get-Process -Name mosaico -ErrorAction SilentlyContinue
    $esc  = [char]27
    $indicator = if ($proc) { "$esc[36m◆$esc[0m " } else { "$esc[90m◇$esc[0m " }
    $base = if ($global:MosaicoBasePrompt) {
        & $global:MosaicoBasePrompt
    } else {
        "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
    }
    "$indicator$base"
}
'@

        Set-Content -Path $ProfileScript -Value $profileBody -Encoding UTF8
    }
    Write-Info "Wrote profile extension: $ProfileScript"

    # -------- 5b. Wire it into $PROFILE (idempotent) --------
    $sourceLine  = ". `"$ProfileScript`""
    $marker      = "# Mosaico tiling window manager helpers"
    $profilePath = $PROFILE.CurrentUserAllHosts
    if ([string]::IsNullOrWhiteSpace($profilePath)) {
        # Fallback if the host doesn't expose $PROFILE.
        $profilePath = Join-Path $env:USERPROFILE "Documents\PowerShell\profile.ps1"
        if (-not $IsPS7Plus) {
            $profilePath = Join-Path $env:USERPROFILE "Documents\WindowsPowerShell\profile.ps1"
        }
    }

    if (-not $DryRun -and -not (Test-Path $profilePath)) {
        New-Item -ItemType File -Path $profilePath -Force | Out-Null
    }

    $alreadyWired = $false
    if (-not $DryRun -and (Test-Path $profilePath)) {
        $profileContent = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
        if ($profileContent) {
            if ($profileContent.Contains($ProfileScript) -or $profileContent.Contains($marker)) {
                $alreadyWired = $true
            }
        }
    }

    if ($alreadyWired) {
        Write-Info "Already sourced from `$PROFILE"
    } else {
        Invoke-Or-Dry "Add source line to `$PROFILE" {
            Add-Content -Path $profilePath -Value "`r`n$marker`r`n$sourceLine"
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
        Invoke-Mosaico -ExePath $exePath -Arguments @("autostart", "enable")
    }
    Write-Info "Mosaico will start on login"
    Write-Host "     Disable with: mosaico autostart disable" -ForegroundColor DarkGray
}

# ─── Step 7: Verify ────────────────────────────────────────────────────
Write-Step "7/7  Verify"

if ($DryRun) {
    Write-Host "   ~ [dry-run] Would run: mosaico doctor" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  Dry run complete. Re-run without -DryRun to apply." -ForegroundColor Magenta
    Write-Host ""
    exit 0
}

$verifyOk = $true

if (Test-Path $exePath) {
    try {
        $ver = ((& $exePath --version 2>$null) -replace '^mosaico\s+', '').Trim()
        Write-Info "mosaico --version → $ver"
    } catch {
        Write-Warn "Binary present but failed to run --version"
        $verifyOk = $false
    }
} else {
    Write-Warn "Binary not found at $exePath"
    $verifyOk = $false
}

if (-not $SkipConfig) {
    if (Test-Path (Join-Path $ConfigDir "config.toml")) {
        Write-Info "Config present: $ConfigDir"
    } else {
        Write-Warn "Config missing at $ConfigDir"
        $verifyOk = $false
    }
}

if (-not $SkipProfile) {
    if (Test-Path $ProfileScript) {
        Write-Info "Profile script: $ProfileScript"
    } else {
        Write-Warn "Profile script missing: $ProfileScript"
        $verifyOk = $false
    }
}

try {
    Invoke-Mosaico -ExePath $exePath -Arguments @("doctor")
} catch {
    Write-Warn "mosaico doctor reported an issue (see output above)"
}

Write-Host ""
if ($verifyOk) {
    Write-Host "  ✓ Setup complete." -ForegroundColor Green
    Write-Host "  Reload your shell:  . `$PROFILE" -ForegroundColor DarkGray
} else {
    Write-Host "  ! Setup finished with warnings." -ForegroundColor Yellow
    Write-Host "  Run 'mosaico doctor' for details." -ForegroundColor DarkGray
}
Write-Host ""