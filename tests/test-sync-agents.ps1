$ErrorActionPreference = 'Stop'

function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$OriginalRoot = Split-Path -Parent $PSScriptRoot
$Temp = Join-Path ([IO.Path]::GetTempPath()) ('sync-agents-' + [guid]::NewGuid().ToString('N'))
$Root = Join-Path $Temp 'repo'
New-Item -ItemType Directory -Path $Root -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $OriginalRoot 'scripts'), (Join-Path $OriginalRoot 'skills'), (Join-Path $OriginalRoot 'agents') -Destination $Root -Recurse
$Profile = Join-Path $Temp 'profile'
New-Item -ItemType Directory -Path $Profile -Force | Out-Null
$OrigUserProfile = $env:USERPROFILE
$env:USERPROFILE = $Profile
$env:SYNC_AGENTS_TEST_COPY_FALLBACK = '1'
try {
    $SyncScript = Join-Path $Root 'scripts\sync-agents.ps1'
    $RepoSkills = Join-Path $Root 'skills'
    $First = Join-Path $RepoSkills 'systematic-debugging'
    $FirstTarget = Join-Path $Profile '.agents\skills\systematic-debugging'

    # 1. Dry-run enumerates planned skill distribution on standard output
    $Dry = & $SyncScript -DryRun -All *>&1 | Out-String
    Assert ($Dry.Contains($FirstTarget)) 'Initial dry-run omitted planned skill distribution.'
    Assert ($Dry.Contains((Join-Path $Profile '.claude\skills\systematic-debugging'))) 'Dry-run with -All omitted downstream skill distribution.'

    # 2. Smart detection syncs present targets and avoids creating ghost directories
    New-Item -ItemType Directory -Path (Join-Path $Profile '.omp\agent') -Force | Out-Null
    $SavedPath = $env:PATH
    try {
        $env:PATH = "$env:SystemRoot\System32"
        & $SyncScript | Out-Null
    } finally {
        $env:PATH = $SavedPath
    }
    Assert (Test-Path (Join-Path $Profile '.omp\agent\AGENTS.md')) 'Detected .omp target was not synced.'
    Assert (-not (Test-Path (Join-Path $Profile '.omo'))) 'Ghost .omo directory should not be created without -All.'

    # 3. Copy fallback, managed copy refresh, and private skill preservation
    $PrivateTarget = Join-Path $Profile '.claude\skills\systematic-debugging'
    New-Item -ItemType Directory -Path $PrivateTarget -Force | Out-Null
    Set-Content (Join-Path $PrivateTarget 'private.txt') 'private'
    & $SyncScript -All | Out-Null
    Assert (Test-Path (Join-Path $FirstTarget 'SKILL.md')) 'Copy fallback did not create skill contents.'
    Set-Content (Join-Path $First 'SKILL.md') 'updated source'
    & $SyncScript -All | Out-Null
    Assert ((Get-Content (Join-Path $FirstTarget 'SKILL.md') -Raw).Trim() -eq 'updated source') 'Managed copy was not updated.'
    $Downstream = Join-Path $Profile '.omp\agent\skills\systematic-debugging\SKILL.md'
    Assert ((Get-Content $Downstream -Raw).Trim() -eq 'updated source') 'Downstream copy was not updated.'
    Assert ((Get-Content (Join-Path $PrivateTarget 'private.txt') -Raw).Trim() -eq 'private') 'Existing private skill was overwritten.'

    # 4. Dry-run never mutates existing skill directories
    $OtherTarget = Join-Path $Profile '.config\opencode\skills\systematic-debugging'
    New-Item -ItemType Directory -Path $OtherTarget -Force | Out-Null
    Set-Content (Join-Path $OtherTarget 'local.txt') 'local'
    & $SyncScript -DryRun | Out-Null
    Assert (Test-Path (Join-Path $OtherTarget 'local.txt')) 'Dry-run changed an existing skill directory.'

    # 5. Hermes external_dirs awareness skips redundant item-level syncing
    $HermesDir = Join-Path $Profile '.hermes'
    New-Item -ItemType Directory -Path $HermesDir -Force | Out-Null
    Remove-Item -LiteralPath (Join-Path $HermesDir 'skills') -Recurse -Force -ErrorAction SilentlyContinue
    $TargetSkillsSlash = (Join-Path $Profile '.agents\skills').Replace('\', '/')
    Set-Content (Join-Path $HermesDir 'config.yaml') "skills:`n  external_dirs:`n    - $TargetSkillsSlash"
    $HermesOut = & $SyncScript *>&1 | Out-String
    Assert ($HermesOut.Contains('Hermes external_dirs already includes')) 'Hermes external_dirs detection failed.'
    Assert (-not (Test-Path (Join-Path $HermesDir 'skills'))) 'Hermes skills directory should not be populated when external_dirs is configured.'

    Write-Output 'sync-agents regression tests passed'
} finally {
    $env:USERPROFILE = $OrigUserProfile
    Remove-Item Env:\SYNC_AGENTS_TEST_COPY_FALLBACK -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}
