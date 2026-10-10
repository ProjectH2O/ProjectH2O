<#
Builds Project H2O (TeknoParrotUI + OpenParrot + H2ODashboard) and packs it into out\ProjectH2O.zip.

    .\package.ps1                         components next to this repo (..\TeknoParrotUI, ..\OpenParrot, ..\H2ODashboard)
    .\package.ps1 -Source src             components in src\ (the release workflow checks them out there)
    .\package.ps1 -Version v1.0           version written to versions.txt (default: this repo's git describe)

Needs: Visual Studio 2022 or later with the C++ v143 toolset and .NET Framework 4.8 targeting, the .NET SDK, git.
Works in Windows PowerShell 5.1 and PowerShell 7.
#>
param(
    [string]$Source = '..',
    [string]$Version = '',
    [string]$Toolset = 'v143'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$src = (Resolve-Path (Join-Path $root $Source)).Path
$tpui = Join-Path $src 'TeknoParrotUI'
$openParrot = Join-Path $src 'OpenParrot'
$dashboard = Join-Path $src 'H2ODashboard'
$out = Join-Path $root 'out'
$stage = Join-Path $out 'ProjectH2O'

function Step($text) { Write-Host "==> $text" -ForegroundColor Cyan }

function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}

# MSBuild from a Visual Studio instance that has the C++ toolset (VS 2022 preferred: v143 ships with it)
function Find-MSBuild {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { throw 'vswhere.exe not found: install Visual Studio 2022 or later' }
    foreach ($range in @('[17.0,18.0)', '[17.0,)')) {
        $found = & $vswhere -products * -version $range -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
        if ($found) { return $found }
    }
    throw 'No Visual Studio with the C++ x86/x64 build tools found'
}

foreach ($dir in @($tpui, $openParrot, $dashboard)) {
    if (-not (Test-Path $dir)) { throw "Component not found: $dir" }
}
$msbuild = Find-MSBuild
Write-Host "MSBuild: $msbuild"

if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory $stage | Out-Null

# ---- OpenParrot (32-bit only: H2Overdrive is a 32-bit game) ----
Step 'OpenParrot'
Push-Location $openParrot
try {
    Invoke-Checked '.\premake5.exe' @('vs2019')
    # Each project's post-build step runs "if not exist output mkdir output"; in a parallel (-m) build
    # two projects can race on it and the second mkdir fails, so create the folder up front
    New-Item -ItemType Directory -Force (Join-Path $openParrot 'build\bin\release\output') | Out-Null
    Invoke-Checked $msbuild @('OpenParrot.sln', '-p:Configuration=Release', '-p:Platform=Win32',
        "-p:PlatformToolset=$Toolset", '-m', '-v:minimal', '-nologo')
} finally { Pop-Location }
$opOut = Join-Path $openParrot 'build\bin\release\output'
$opDest = New-Item -ItemType Directory (Join-Path $stage 'OpenParrotWin32')
foreach ($file in @('OpenParrot.dll', 'OpenParrotLoader.exe', 'OpenParrotKonamiLoader.exe', 'bngrw.dll', 'iDmacDrv32.dll')) {
    Copy-Item (Join-Path $opOut $file) $opDest
}

# ---- TeknoParrotUI ----
Step 'TeknoParrotUI'
Push-Location $tpui
try {
    Invoke-Checked $msbuild @('TeknoParrotUI.sln', '-t:Restore', '-p:RestorePackagesConfig=true',
        '-p:Configuration=Release', '-p:Platform=x86', '-v:minimal', '-nologo')
    Invoke-Checked $msbuild @('TeknoParrotUI.sln', '-p:Configuration=Release', '-p:Platform=x86',
        '-m', '-v:minimal', '-nologo')
} finally { Pop-Location }
Copy-Item -Recurse (Join-Path $tpui 'bin\x86\Release\*') $stage
$icons = New-Item -ItemType Directory (Join-Path $stage 'Icons')
Copy-Item (Join-Path $root 'media\icons\H2Overdrive.png') $icons

# ---- H2ODashboard ----
Step 'H2ODashboard'
Push-Location $dashboard
try {
    Invoke-Checked 'dotnet' @('build', '-c', 'Release', '-nologo', '-v', 'minimal')
} finally { Pop-Location }
$dashDest = New-Item -ItemType Directory (Join-Path $stage 'H2ODashboard')
Copy-Item -Recurse (Join-Path $dashboard 'bin\Release\net48\*') $dashDest
# per-user files a local run may have left next to the exe
Remove-Item (Join-Path $dashDest 'H2ODashboard*.ini') -ErrorAction SilentlyContinue

# ---- Clean up and record versions ----
Get-ChildItem $stage -Recurse -Include '*.pdb' | Remove-Item
foreach ($userData in @('ParrotData.xml', 'UserProfiles', 'OpenParrotWin32.stock')) {
    $path = Join-Path $stage $userData
    if (Test-Path $path) { Remove-Item -Recurse -Force $path }
}

function Get-Revision($dir) {
    if (-not (Test-Path (Join-Path $dir '.git'))) { return 'unknown (not a git checkout)' }
    $ErrorActionPreference = 'Continue'   # git writes to stderr for repos without tags
    $rev = (& git -C $dir describe --tags --always --dirty 2>$null)
    $branch = (& git -C $dir rev-parse --abbrev-ref HEAD 2>$null)
    if (-not $rev) { return 'unknown' }
    return "$rev ($branch)"
}
if (-not $Version) { $Version = Get-Revision $root }
$lines = @(
    "Project H2O $Version",
    "Built $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC",
    '',
    "TeknoParrotUI  $(Get-Revision $tpui)",
    "OpenParrot     $(Get-Revision $openParrot)",
    "H2ODashboard   $(Get-Revision $dashboard)"
)
[System.IO.File]::WriteAllLines((Join-Path $stage 'versions.txt'), $lines)

Step 'Zip'
$zip = Join-Path $out 'ProjectH2O.zip'
Compress-Archive -Path $stage -DestinationPath $zip
Write-Host "Done: $zip" -ForegroundColor Green
Get-Content (Join-Path $stage 'versions.txt')
