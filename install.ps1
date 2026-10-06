#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstrap installer for the PowerShell + Oh My Posh setup.
.DESCRIPTION
    Downloads setup.ps1 and setup-pwsh.ps1 from a GitHub repo (or a URL /
    local path), then invokes setup.ps1. Self-elevates to Administrator.

    Intended to be run as:
        irm
https://raw.githubusercontent.com/zhexhem/mosaico/main/install.ps1 | iex

    Or locally:
        .\install.ps1
.PARAMETER Repo
    GitHub repo in owner/name form (e.g. "octocat/my-pwsh-setup").
    Ignored if -SourceUrl is set.
.PARAMETER Branch
    Branch or tag to pull from. Default: main.
.PARAMETER SourceUrl
    Full base URL to pull setup.ps1 / setup-pwsh.ps1 from
    (e.g. a raw.githubusercontent.com URL or an internal artifact server).
.PARAMETER SetupArgs
    Hashtable of arguments to forward to setup.ps1.
.PARAMETER KeepTemp
    Keep the downloaded scripts in %TEMP% after the run.
.NOTES
    Windows 10/11. No admin required to launch; self-elevates.
#>
[CmdletBinding()]
param(
    [string]   $Repo    = 'your-user/your-repo',
    [string]   $Branch  = 'main',
    [string]   $SourceUrl,
    [hashtable]$SetupArgs = @{},
    [switch]   $KeepTemp
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $c = switch ($Level) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'Cyan'} }
    Write-Host ("[{0,-5}] {1}" -f $Level, $Message) -ForegroundColor $c
}

# --- Self-elevate ---
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Log 'Elevation required. Relaunching as Administrator...' 'WARN'

    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-Repo',   "`"$Repo`"",
        '-Branch', "`"$Branch`""
    )
    if ($SourceUrl) { $argList += @('-SourceUrl', "`"$SourceUrl`"") }
    if ($KeepTemp)  { $argList += '-KeepTemp' }

    # Forward SetupArgs as -SetupArgs (hashtable literal)
    if ($SetupArgs.Count -gt 0) {
        $pairs = ($SetupArgs.GetEnumerator() | ForEach-Object {
            "'$($_.Key)' = '$($_.Value -replace "'","''")'"
        }) -join '; '
        $argList += @('-SetupArgs', "@{ $pairs }")
    }

    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    return
}

# --- Resolve source URLs ---
if (-not $SourceUrl) {
    $SourceUrl = "https://raw.githubusercontent.com/$Repo/$Branch"
}
$SourceUrl = $SourceUrl.TrimEnd('/')

$tempDir = Join-Path $env:TEMP ('setup-pwsh-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
Write-Log "Downloading scripts to $tempDir ..."

$files = @('setup.ps1', 'setup-pwsh.ps1')
foreach ($f in $files) {
    $url  = "$SourceUrl/$f"
    $dest = Join-Path $tempDir $f
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
        Write-Log "Downloaded $f" 'OK'
    } catch {
        throw "Failed to download $f from $url : $($_.Exception.Message)"
    }
}

# --- Invoke setup.ps1 ---
Write-Log 'Launching setup.ps1 ...'
$setup = Join-Path $tempDir 'setup.ps1'
try {
    & $setup @SetupArgs -ScriptRoot $tempDir
}
finally {
    if (-not $KeepTemp) {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Log "Scripts kept at $tempDir" 'WARN'
    }
}