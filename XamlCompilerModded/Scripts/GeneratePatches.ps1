param (
    [Parameter(Mandatory)]
    [string]$WorkDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$SourceDir = Join-Path $WorkDir 'Source'
$PatchDir  = Join-Path $WorkDir 'Patches'

if (-not (Test-Path $SourceDir)) {
    throw "Source directory missing"
}

Push-Location $SourceDir
git add .
Pop-Location

# Recreate Patches
if (Test-Path $PatchDir) {
    Remove-Item -Recurse -Force $PatchDir
}
New-Item -ItemType Directory -Path $PatchDir | Out-Null

# Helper: write UTF-8 without BOM
function Write-Utf8NoBom {
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

Push-Location $SourceDir

# Ask Git what actually changed
$Status = git status --porcelain

foreach ($Line in $Status) {
    # Format: XY <path>
    $Code = $Line.Substring(0, 2).Trim()
    $RelPath = $Line.Substring(3)

    # Normalize to POSIX for patch paths
    $RelPathPosix = $RelPath -replace '\\', '/'

    $PatchName = ($RelPathPosix -replace '/', '_') + '.patch'
    $PatchPath = Join-Path $PatchDir $PatchName

    switch ($Code) {
        'M' {
            $Diff = git diff --binary HEAD -- "$RelPathPosix" | Out-String
            Write-Utf8NoBom -Path $PatchPath -Content $Diff
            Write-Host "Patched modified file: $RelPath"
        }

        'A' {
            $Diff = git diff --binary HEAD -- "$RelPathPosix" | Out-String
            Write-Utf8NoBom -Path $PatchPath -Content $Diff
            Write-Host "Patched new file: $RelPath"
        }

        'D' {
            $Diff = git diff --binary HEAD -- "$RelPathPosix" | Out-String
            Write-Utf8NoBom -Path $PatchPath -Content $Diff
            Write-Host "Patched deleted file: $RelPath"
        }
    }
}

Pop-Location

Write-Host ""
Write-Host "Per-file patches generated:"
Write-Host "  $PatchDir"
