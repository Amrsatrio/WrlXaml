param (
    [string]$SdkVersion
)

# Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =========================================================
# Paths
# =========================================================

$RepoRoot = Resolve-Path "$PSScriptRoot\.."
$WorkRoot = Join-Path $RepoRoot 'Work'

# =========================================================
# Locate Windows SDK root
# =========================================================

$SdkRoot = (Get-ItemProperty `
    'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' `
).KitsRoot10

if (-not $SdkRoot) {
    throw "Windows SDK not found (KitsRoot10 missing)"
}

$BinRoot = Join-Path $SdkRoot 'bin'

# =========================================================
# Resolve SDK version
# =========================================================

if ($SdkVersion) {
    $CandidateDir = Join-Path $BinRoot $SdkVersion

    if (-not (Test-Path $CandidateDir)) {
        throw "Requested SDK version not found: $SdkVersion"
    }
}
else {
    $SdkVersion =
        Get-ChildItem $BinRoot -Directory |
        Where-Object { $_.Name -match '^[0-9]' } |
        Sort-Object Name -Descending |
        Select-Object -First 1 |
        ForEach-Object { $_.Name }

    if (-not $SdkVersion) {
        throw "No numeric Windows SDK versions found"
    }
}

Write-Host "Using Windows SDK version:"
Write-Host "  $SdkVersion"

# =========================================================
# Locate XAML compiler DLL
# =========================================================

$XamlDllName = 'Microsoft.Windows.UI.Xaml.Build.Tasks.dll'
$XamlDll = Join-Path $BinRoot `
    "$SdkVersion\XamlCompiler\$XamlDllName"

if (-not (Test-Path $XamlDll)) {
    throw "XAML compiler not found for SDK $SdkVersion"
}

Write-Host "Found XAML compiler:"
Write-Host "  $XamlDll"

# =========================================================
# Hash DLL
# =========================================================

$Hash = (Get-FileHash $XamlDll -Algorithm SHA1).Hash.ToLowerInvariant()

$WorkDir  = Join-Path $WorkRoot "$SdkVersion\$Hash"
$SourceDir = Join-Path $WorkDir 'Source'

# =========================================================
# Safety: never overwrite Source
# =========================================================

if (Test-Path $SourceDir) {
    throw "Source already exists for this SDK + DLL hash"
}

# =========================================================
# Ensure ilspycmd
# =========================================================

$ToolsDir = Join-Path $RepoRoot 'Tools\ilspycmd'
$IlspyCmd = Join-Path $ToolsDir 'ilspycmd.exe'

if (-not (Test-Path $IlspyCmd)) {
    New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null

    & dotnet tool install ilspycmd `
        --tool-path $ToolsDir `
        | Out-Null
}

# =========================================================
# Prepare directories
# =========================================================

New-Item -ItemType Directory -Force -Path $SourceDir | Out-Null

# =========================================================
# Preserve original Microsoft-signed DLL
# =========================================================

Copy-Item `
    -Path $XamlDll `
    -Destination (Join-Path $WorkDir $XamlDllName) `
    -Force

# =========================================================
# Decompile (Clean)
# =========================================================

& $IlspyCmd `
    -p `
    --nested-directories `
    -o $SourceDir `
    $XamlDll

# =========================================================
# Generate solution
# =========================================================
$SlnName = "WrlXamlCompiler_$($SdkVersion)_$($Hash.Substring(0,8)).sln"
$SlnPath = Join-Path $SourceDir $SlnName

$SlnBaseName = [System.IO.Path]::GetFileNameWithoutExtension($SlnName)

dotnet new sln --format sln --name $SlnBaseName --output $SourceDir | Out-Null

$CsprojPath = Join-Path $SourceDir ([System.IO.Path]::GetFileNameWithoutExtension($XamlDllName) + '.csproj')
dotnet sln $SlnPath add $CsprojPath | Out-Null

# =========================================================
# Setup Git repository in Source
# =========================================================

Push-Location $SourceDir

git init | Out-Null

# Setup .gitignore
@"
bin/
obj/
*.dll
*.exe
*.pdb

packages/
*.nupkg
project.assets.json
*.cache

.vs/
.idea/
*.user
*.suo
*.DotSettings.user

Thumbs.db
Desktop.ini
"@ | Set-Content -Encoding ASCII '.gitignore'

# Make the ONLY commit of the repository
git add .
git commit -m "Clean decompile baseline" | Out-Null

# Apply patches (if present)
function Apply-Patch {
    param (
        [string]$PatchPath
    )

    if ($PatchPath -like '*.csproj.patch') {
        git apply --ignore-space-change --ignore-whitespace $PatchPath
    }
    else {
        git apply --whitespace=nowarn $PatchPath
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to apply patch: $PatchPath"
    }
}

function Apply-PatchDir {
    param ([string]$Dir)

    Write-Host "Applying patches in $Dir"
    Get-ChildItem $Dir -Filter *.patch | Sort-Object Name | ForEach-Object {
        Write-Host "  Applying $($_.Name)"
        Apply-Patch $_.FullName
    }
}

# Always apply common patches first
$CommonDir = Join-Path $RepoRoot 'Patches\Common'
if (Test-Path $CommonDir) {
    Apply-PatchDir $CommonDir
}

$SdkVer = [Version]$SdkVersion

# Collect version-scoped patch dirs with parsed metadata
$VersionPatchDirs =
    Get-ChildItem (Join-Path $RepoRoot 'Patches') -Directory |
    Where-Object { $_.Name -match '^Sdk_(eq|lt|le|ge|gt)_(.+)$' } |
    ForEach-Object {
        [PSCustomObject]@{
            Path     = $_.FullName
            Relation = $Matches[1]
            Version  = [Version]$Matches[2]
        }
    }

# Sort by VERSION, not name
$VersionPatchDirs |
    Sort-Object Version |
    ForEach-Object {
        $PatchVer = [version]$_.Version
        $Cmp = $SdkVer.CompareTo($PatchVer)

        $Apply = switch ($_.Relation) {
            'eq' { $Cmp -eq 0 }
            'lt' { $Cmp -lt 0 }
            'le' { $Cmp -le 0 }
            'ge' { $Cmp -ge 0 }
            'gt' { $Cmp -gt 0 }
        }

        if ($Apply) {
            Write-Host "SDK version $SdkVer matches condition '$($_.Relation) $($_.Version)'"
            Apply-PatchDir $_.Path
        }
    }

# Track new files from patches
git add .

# Prevent further commits from being made
$HookDir = Join-Path $SourceDir '.git\hooks'
$Hook = Join-Path $HookDir 'pre-commit'

@"
#!/bin/sh
echo "ERROR: Commits are disabled in this disposable repository."
echo "This repository exists only for diff purposes."
exit 1
"@ | Set-Content -Encoding ASCII $Hook

Pop-Location

# =========================================================
# Metadata + shortcut script
# =========================================================

$XamlDll | Set-Content (Join-Path $WorkDir 'SourceDll.txt')

$Shortcut = Join-Path $WorkDir 'GeneratePatchesForThisDll.bat'

@"
@echo off
setlocal

REM =====================================================
REM Fixed layout contract:
REM   Work\<Ver>\<Hash>\GeneratePatchesForThisDll.bat
REM   Scripts\GeneratePatches.ps1
REM =====================================================

set THIS_DIR=%~dp0
set THIS_DIR=%THIS_DIR:~0,-1%

set REPO_ROOT=%THIS_DIR%\..\..\..
set SCRIPT=%REPO_ROOT%\Scripts\GeneratePatches.ps1

powershell ^
  -NoProfile ^
  -ExecutionPolicy Bypass ^
  -File "%SCRIPT%" ^
  -WorkDir "%THIS_DIR%"

pause
"@ | Set-Content -Encoding ASCII $Shortcut


Write-Host ""
Write-Host "SUCCESS"
Write-Host "Work directory:"
Write-Host "  $WorkDir"
