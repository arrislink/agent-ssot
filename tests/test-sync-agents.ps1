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
$env:USERPROFILE = $Profile
$env:SYNC_AGENTS_TEST_COPY_FALLBACK = '1'
try {
    $RepoSkills = Join-Path $Root 'skills'
    $First = Join-Path $RepoSkills 'systematic-debugging'
    $FirstTarget = Join-Path $Profile '.agents\skills\systematic-debugging'
    $Dry = & (Join-Path $Root 'scripts\sync-agents.ps1') -DryRun 2>&1 | Out-String
    Assert ($Dry.Contains($FirstTarget)) 'Initial dry-run omitted planned skill distribution.'

    $PrivateTarget = Join-Path $Profile '.claude\skills\systematic-debugging'
    New-Item -ItemType Directory -Path $PrivateTarget -Force | Out-Null
    Set-Content (Join-Path $PrivateTarget 'private.txt') 'private'
    & (Join-Path $Root 'scripts\sync-agents.ps1') -All | Out-Null
    Assert (Test-Path (Join-Path $FirstTarget 'SKILL.md')) 'Copy fallback did not create skill contents.'
    Set-Content (Join-Path $First 'SKILL.md') 'updated source'
    & (Join-Path $Root 'scripts\sync-agents.ps1') -All | Out-Null
    Assert ((Get-Content (Join-Path $FirstTarget 'SKILL.md') -Raw).Trim() -eq 'updated source') 'Managed copy was not updated.'
    $Downstream = Join-Path $Profile '.omp\agent\skills\systematic-debugging\SKILL.md'
    Assert ((Get-Content $Downstream -Raw).Trim() -eq 'updated source') 'Downstream copy was not updated.'
    Assert ((Get-Content (Join-Path $PrivateTarget 'private.txt') -Raw).Trim() -eq 'private') 'Existing private skill was overwritten.'

    $OtherTarget = Join-Path $Profile '.config\opencode\skills\systematic-debugging'
    New-Item -ItemType Directory -Path $OtherTarget -Force | Out-Null
    Set-Content (Join-Path $OtherTarget 'local.txt') 'local'
    & (Join-Path $Root 'scripts\sync-agents.ps1') -DryRun | Out-Null
    Assert (Test-Path (Join-Path $OtherTarget 'local.txt')) 'Dry-run changed an existing skill directory.'

    Write-Output 'sync-agents regression tests passed'
} finally {
    Remove-Item Env:\SYNC_AGENTS_TEST_COPY_FALLBACK -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}
