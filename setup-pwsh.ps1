#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Complete PowerShell 7 + Oh My Posh + Oh My Zsh-style setup.
.DESCRIPTION
    Installs PowerShell 7, Oh My Posh, a Nerd Font, required PowerShell
    modules, and writes a fully configured PowerShell 7 profile.

    Safe to re-run; existing profile is timestamped and backed up first.
.PARAMETER Theme
    Oh My Posh theme name (e.g. jandedobbeleer, paradox, unicorn) or a
    full path to a .omp.json file.
.PARAMETER NerdFont
    Nerd Font family name from nerdfonts.com (e.g. CaskaydiaCove, JetBrainsMono).
.PARAMETER Modules
    PowerShell modules to install into CurrentUser scope.
.PARAMETER SkipFonts
    Skip Nerd Font installation.
.PARAMETER SkipProfile
    Skip writing the PowerShell profile.
.PARAMETER SkipWinget
    Skip WinGet-based installs (assumes tools are already present).
.EXAMPLE
    .\setup-pwsh.ps1
.EXAMPLE
    .\setup-pwsh.ps1 -Theme paradox -NerdFont JetBrainsMono
.NOTES
    Windows 10/11. Requires Administrator. Uses WinGet + PSGallery.
#>
[CmdletBinding()]
param(
    [string]   $Theme    = 'jandedobbeleer',
    [string]   $NerdFont = 'CaskaydiaCove',
    [string[]] $Modules  = @('posh-git', 'Terminal-Icons', 'z', 'CompletionPredictor'),
    [switch]   $SkipFonts,
    [switch]   $SkipProfile,
    [switch]   $SkipWinget
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# PS 5.1 needs TLS 1.2 for PSGallery / GitHub downloads
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:Warnings = [System.Collections.Generic.List[string]]::new()

#region ---------- Helpers ----------
function Write-Step {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR','SKIP')][string]$Status = 'INFO'
    )
    $color = switch ($Status) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'SKIP'  { 'DarkGray' }
        default { 'Cyan' }
    }
    Write-Host ('[{0,-5}] {1}' -f $Status, $Message) -ForegroundColor $color
    if ($Status -in 'WARN','ERROR') { $script:Warnings.Add("$Status: $Message") }
}

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Update-SessionPath {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ';'
}

function Install-WingetPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name
    )
    if ($SkipWinget) {
        Write-Step "Skipping WinGet install of $Name (-SkipWinget)." 'SKIP'
        return
    }

    # Pre-check: already installed?
    $list = & winget list --id $Id --exact --accept-source-agreements 2>$null
    if ($list -match [regex]::Escape($Id)) {
        Write-Step "$Name already installed." 'OK'
        return
    }

    Write-Step "Installing $Name via WinGet..."
    & winget install --id $Id --exact --silent `
        --accept-package-agreements --accept-source-agreements `
        --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        Write-Step "WinGet returned exit code $LASTEXITCODE for $Name." 'WARN'
    } else {
        Write-Step "$Name installed." 'OK'
    }
    Update-SessionPath
}
#endregion

#region ---------- 1. WinGet ----------
Write-Step 'Checking WinGet...'
if (-not (Test-CommandExists 'winget')) {
    Write-Step 'WinGet not found. Opening Microsoft Store to install App Installer...' 'WARN'
    Start-Process 'ms-windows-store://pdp/?productid=9NBLGGH4NNS1' -ErrorAction SilentlyContinue
    throw 'WinGet is required. Install App Installer from the Microsoft Store and re-run.'
}
Write-Step 'WinGet found.' 'OK'
#endregion

#region ---------- 2. PowerShell 7 ----------
Write-Step 'Checking PowerShell 7...'
$pwshPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if (-not (Test-Path $pwshPath)) {
    Install-WingetPackage -Id 'Microsoft.PowerShell' -Name 'PowerShell 7'
}
if (-not (Test-Path $pwshPath)) {
    $found = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($found) { $pwshPath = $found.Source }
}
if (-not (Test-Path $pwshPath)) {
    throw 'PowerShell 7 not found after install attempt.'
}
Write-Step "PowerShell 7 at $pwshPath" 'OK'
Update-SessionPath
#endregion

#region ---------- 3. Git ----------
Write-Step 'Checking Git...'
if (-not (Test-CommandExists 'git')) {
    Install-WingetPackage -Id 'Git.Git' -Name 'Git for Windows'
}
if (Test-CommandExists 'git') { Write-Step 'Git available.' 'OK' }
else { Write-Step 'Git unavailable; posh-git will install but Git features are limited.' 'WARN' }
#endregion

#region ---------- 4. Oh My Posh ----------
Write-Step 'Checking Oh My Posh...'
if (-not (Test-CommandExists 'oh-my-posh')) {
    Install-WingetPackage -Id 'JanDeDobbeleer.OhMyPosh' -Name 'Oh My Posh'
}
if (Test-CommandExists 'oh-my-posh') { Write-Step 'Oh My Posh available.' 'OK' }
else { Write-Step 'Oh My Posh is not on PATH.' 'WARN' }
#endregion

#region ---------- 5. Nerd Font ----------
if ($SkipFonts) {
    Write-Step 'Skipping Nerd Font installation.' 'SKIP'
} else {
    Write-Step "Installing Nerd Font: $NerdFont..."
    $zip     = Join-Path $env:TEMP "$NerdFont.zip"
    $extract = Join-Path $env:TEMP "$NerdFont"
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop

        $url = "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/$NerdFont.zip"
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -ErrorAction Stop
        if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $extract -Force

        $fontReg   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
        $installed = 0

        Get-ChildItem -Path $extract -Recurse -Include *.ttf, *.otf | ForEach-Object {
            $file = $_
            try {
                # Read the real family name from the font file
                $pfc = New-Object System.Drawing.Text.PrivateFontCollection
                $pfc.AddFontFile($file.FullName)
                $family = if ($pfc.Families.Count -gt 0) { $pfc.Families[0].Name } else { $file.BaseName }
                $pfc.Dispose()

                $dest = Join-Path "$env:WINDIR\Fonts" $file.Name
                if (-not (Test-Path $dest)) { Copy-Item $file.FullName $dest -Force }

                New-ItemProperty -Path $fontReg -Name "$family (TrueType)" `
                    -Value $file.Name -PropertyType String -Force | Out-Null
                $installed++
            } catch {
                Write-Verbose "Skipped font file $($file.Name): $_"
            }
        }
        Write-Step "Registered $installed font file(s) from $NerdFont." 'OK'
    } catch {
        Write-Step "Nerd Font install failed: $($_.Exception.Message)" 'WARN'
        Write-Step 'Install manually from https://www.nerdfonts.com/font-downloads' 'WARN'
    } finally {
        Remove-Item $zip, $extract -Recurse -Force -ErrorAction SilentlyContinue
    }
}
#endregion

#region ---------- 6. PowerShell Modules ----------
Write-Step 'Installing PowerShell modules (CurrentUser scope)...'
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Write-Step 'Bootstrapping NuGet provider...' 'INFO'
    & $pwshPath -NoProfile -Command `
        "Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null"
}
& $pwshPath -NoProfile -Command `
    "if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted }"

$moduleList   = ($Modules | ForEach-Object { "'$_'" }) -join ', '
$moduleScript = @"
`$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
`$mods = @($moduleList)
foreach (`$m in `$mods) {
    try {
        `$existing = Get-Module -ListAvailable -Name `$m | Select-Object -First 1
        if (`$existing) {
            Write-Host ('  [SKIP] {0} already installed ({1})' -f `$m, `$existing.Version) -ForegroundColor DarkGray
            continue
        }
        Write-Host ('  [INFO] Installing {0}...' -f `$m) -ForegroundColor Cyan
        Install-Module -Name `$m -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
        Write-Host ('  [ OK ] {0} installed' -f `$m) -ForegroundColor Green
    } catch {
        Write-Host ('  [WARN] {0} failed: {1}' -f `$m, `$_.Exception.Message) -ForegroundColor Yellow
    }
}
"@
& $pwshPath -NoProfile -Command $moduleScript
#endregion

#region ---------- 7. Execution Policy ----------
Write-Step 'Setting execution policy (CurrentUser -> RemoteSigned)...'
try {
    & $pwshPath -NoProfile -Command `
        "Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force"
    Write-Step 'Execution policy set.' 'OK'
} catch {
    Write-Step "Could not set execution policy: $($_.Exception.Message)" 'WARN'
}
#endregion

#region ---------- 8. Profile ----------
if ($SkipProfile) {
    Write-Step 'Skipping profile creation.' 'SKIP'
} else {
    Write-Step 'Writing PowerShell 7 profile...'

    $docs        = [Environment]::GetFolderPath('MyDocuments')
    $profileDir  = Join-Path $docs 'PowerShell'
    $profilePath = Join-Path $profileDir 'Microsoft.PowerShell_profile.ps1'
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }

    # Support either a theme name or a full path to a .omp.json
    if ($Theme -match '[\\/]' -or $Theme -like '*.omp.json') {
        $themeRef = "`"$Theme`""
    } else {
        $themeRef = "`"`$env:POSH_THEMES_PATH\$Theme.omp.json`""
    }

    $profileContent = @"
# ============================================================
# PowerShell Profile - Oh My Posh + Oh My Zsh-style Setup
# Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by setup-pwsh.ps1
# ============================================================

# --- Oh My Posh (prompt theme) ---
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    `$ompTheme = $themeRef
    if (Test-Path `$ompTheme) {
        oh-my-posh init pwsh --config `$ompTheme | Invoke-Expression
    } else {
        oh-my-posh init pwsh | Invoke-Expression
    }
}

# --- PSReadLine (autosuggestions + syntax coloring) ---
if (Get-Module -ListAvailable PSReadLine) {
    Import-Module PSReadLine -ErrorAction SilentlyContinue
    try {
        Set-PSReadLineOption -PredictionSource History
        Set-PSReadLineOption -PredictionViewStyle InlineView
        Set-PSReadLineKeyHandler -Key RightArrow        -Function AcceptSuggestion
        Set-PSReadLineKeyHandler -Chord 'Ctrl+RightArrow' -Function ForwardWord
        Set-PSReadLineKeyHandler -Chord 'Ctrl+Backspace'  -Function BackwardDeleteWord
        Set-PSReadLineOption -Colors @{
            Command   = 'Green'
            Parameter = 'Cyan'
            String    = 'Yellow'
            Operator  = 'Magenta'
            Variable  = 'White'
            Error     = 'Red'
        }
    } catch {
        # Older PSReadLine versions may not support some options
    }
}

# --- Modules (only if available) ---
foreach (`$m in 'posh-git', 'Terminal-Icons', 'z', 'CompletionPredictor') {
    if (Get-Module -ListAvailable -Name `$m) {
        Import-Module `$m -ErrorAction SilentlyContinue
    }
}

# --- Oh My Zsh-style Git aliases ---
function gs  { git status @args }
function ga  { git add @args }
function gc  { git commit @args }
function gp  { git push @args }
function gl  { git log --oneline --graph --decorate @args }
function gd  { git diff @args }
function gco { git checkout @args }
function gcb { git checkout -b @args }
function gst { git stash @args }

# --- Navigation ---
function take {
    param([Parameter(Mandatory)][string]`$Path)
    New-Item -ItemType Directory -Path `$Path -Force | Out-Null
    Set-Location `$Path
}
function ..   { Set-Location .. }
function ...  { Set-Location ../.. }
function .... { Set-Location ../../.. }

# --- Files ---
function ll    { Get-ChildItem -Force @args }
function la    { Get-ChildItem -Force @args }
function touch {
    param([Parameter(Mandatory)][string]`$Path)
    New-Item -ItemType File -Path `$Path -Force | Out-Null
}
function mkcd {
    param([Parameter(Mandatory)][string]`$Path)
    New-Item -ItemType Directory -Path `$Path -Force | Out-Null
    Set-Location `$Path
}

# --- Utility ---
function which {
    param([Parameter(Mandatory)][string]`$Name)
    (Get-Command `$Name -ErrorAction SilentlyContinue).Source
}
"@

    if (Test-Path $profilePath) {
        $backup = "$profilePath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $profilePath $backup
        Write-Step "Backed up existing profile to $backup" 'WARN'
    }

    # UTF-8 without BOM (works in PS 5.1 and 7)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($profilePath, $profileContent, $utf8NoBom)
    Write-Step "Profile written to $profilePath" 'OK'
}
#endregion

#region ---------- 9. Verify ----------
Write-Step 'Verifying installation...'
$verifyScript = @'
$results = [ordered]@{
    'PowerShell version' = $PSVersionTable.PSVersion.ToString()
    'pwsh path'          = (Get-Command pwsh).Source
    'oh-my-posh'         = if (Get-Command oh-my-posh -EA SilentlyContinue) { (oh-my-posh --version) } else { 'MISSING' }
    'profile path'       = $PROFILE
    'profile exists'     = Test-Path $PROFILE
}
$results | ConvertTo-Json -Compress
'@
$json = & $pwshPath -NoProfile -Command $verifyScript
try {
    $report = $json | ConvertFrom-Json
    $report.PSObject.Properties | ForEach-Object {
        $val    = $_.Value
        $status = if ($val -eq 'MISSING' -or $val -eq $false -or -not $val) { 'WARN' } else { 'OK' }
        Write-Step ('{0,-20}: {1}' -f $_.Name, $val) $status
    }
} catch {
    Write-Step "Verification output could not be parsed: $_" 'WARN'
}
#endregion

#region ---------- Summary ----------
Write-Host ''
Write-Host '============================================' -ForegroundColor Magenta
Write-Host '  Setup complete!' -ForegroundColor Green
Write-Host '============================================' -ForegroundColor Magenta
Write-Host ''
if ($script:Warnings.Count -gt 0) {
    Write-Host 'Warnings:' -ForegroundColor Yellow
    $script:Warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host ''
}
Write-Host 'Next steps:' -ForegroundColor White
Write-Host '  1. Windows Terminal > Settings > Startup > Default profile -> PowerShell' -ForegroundColor Gray
Write-Host "  2. Settings > Profiles > PowerShell > Appearance > Font face -> '$NerdFont Nerd Font'" -ForegroundColor Gray
Write-Host '     (Some installs register as ''... NF'' instead.)' -ForegroundColor DarkGray
Write-Host '  3. Restart Windows Terminal.' -ForegroundColor Gray
Write-Host ''
#endregion