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

    # 0. -Check on an unsynced profile returns non-zero without mutating filesystem
    $global:LASTEXITCODE = 0
    $UnsyncedCheckOut = & $SyncScript -Check *>&1 | Out-String
    Assert ($LASTEXITCODE -ne 0) '-Check should return non-zero on unsynced profile.'
    Assert ($UnsyncedCheckOut.Contains('[FAIL]')) '-Check output should include [FAIL] marker.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $Profile '.agents'))) '-Check must not create .agents directory.'

    # 1. Dry-run enumerates planned skill distribution on standard output
    $Dry = & $SyncScript -DryRun -All *>&1 | Out-String
    Assert ($Dry.Contains($FirstTarget)) 'Initial dry-run omitted planned skill distribution.'
    Assert ($Dry.Contains((Join-Path $Profile '.claude\skills\systematic-debugging'))) 'Dry-run with -All omitted downstream skill distribution.'

    # 2. Smart detection syncs present targets and avoids creating ghost directories (including OpenCode split paths)
    New-Item -ItemType Directory -Path (Join-Path $Profile '.omp\agent') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Profile '.config\opencode') -Force | Out-Null
    $SavedPath = $env:PATH
    try {
        $env:PATH = "$env:SystemRoot\System32"
        & $SyncScript | Out-Null
        $global:LASTEXITCODE = 0
        & $SyncScript -Check | Out-Null
        Assert ($LASTEXITCODE -eq 0) '-Check should succeed after smart sync.'
    } finally {
        $env:PATH = $SavedPath
    }
    Assert (Test-Path (Join-Path $Profile '.omp\agent\AGENTS.md')) 'Detected .omp target was not synced.'
    Assert (Test-Path (Join-Path $Profile '.config\opencode\AGENTS.md')) 'Detected .config\opencode target was not synced.'
    Assert (-not (Test-Path (Join-Path $Profile 'AppData\Roaming\opencode'))) 'Ghost AppData\Roaming\opencode directory should not be created when only .config\opencode exists.'
    Assert (-not (Test-Path (Join-Path $Profile '.omo'))) 'Ghost .omo directory should not be created without -All.'

    # 3. Existing instruction file backup and empty .agent-ssot-copy marker safety
    $ClaudeDir = Join-Path $Profile '.claude'
    New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $ClaudeDir 'CLAUDE.md') -Value 'custom instructions'
    $EmptyMarkerSkill = Join-Path $ClaudeDir 'skills\verification-before-completion'
    New-Item -ItemType Directory -Path $EmptyMarkerSkill -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $EmptyMarkerSkill 'keep.txt') -Value 'keep'
    New-Item -ItemType File -Path (Join-Path $ClaudeDir 'skills\.verification-before-completion.agent-ssot-copy') -Force | Out-Null

    # 4. Copy fallback, managed copy refresh, and private skill preservation
    $PrivateTarget = Join-Path $Profile '.claude\skills\systematic-debugging'
    New-Item -ItemType Directory -Path $PrivateTarget -Force | Out-Null
    Set-Content (Join-Path $PrivateTarget 'private.txt') 'private'
    & $SyncScript -All | Out-Null
    $ClaudeBackups = @(Get-ChildItem -LiteralPath $ClaudeDir -Filter 'CLAUDE.md.bak.*')
    Assert ($ClaudeBackups.Count -ge 1) 'Existing CLAUDE.md instruction file was not backed up.'
    Assert ((Get-Content -LiteralPath $ClaudeBackups[0].FullName -Raw).Trim() -eq 'custom instructions') 'CLAUDE.md backup content mismatch.'
    Assert (Test-Path -LiteralPath (Join-Path $EmptyMarkerSkill 'keep.txt')) 'Empty .agent-ssot-copy marker caused skill directory loss or crash.'
    Assert (Test-Path (Join-Path $FirstTarget 'SKILL.md')) 'Copy fallback did not create skill contents.'
    Set-Content (Join-Path $First 'SKILL.md') 'updated source'
    & $SyncScript -All | Out-Null
    Assert ((Get-Content (Join-Path $FirstTarget 'SKILL.md') -Raw).Trim() -eq 'updated source') 'Managed copy was not updated.'
    $Downstream = Join-Path $Profile '.omp\agent\skills\systematic-debugging\SKILL.md'
    Assert ((Get-Content $Downstream -Raw).Trim() -eq 'updated source') 'Downstream copy was not updated.'
    Assert ((Get-Content (Join-Path $PrivateTarget 'private.txt') -Raw).Trim() -eq 'private') 'Existing private skill was overwritten.'

    # 5. Dry-run never mutates existing skill directories
    $OtherTarget = Join-Path $Profile '.config\opencode\skills\systematic-debugging'
    Remove-Item -LiteralPath (Join-Path $Profile '.config\opencode\skills\.systematic-debugging.agent-ssot-copy') -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $OtherTarget -Force | Out-Null
    Set-Content (Join-Path $OtherTarget 'local.txt') 'local'
    & $SyncScript -DryRun | Out-Null
    Assert (Test-Path (Join-Path $OtherTarget 'local.txt')) 'Dry-run changed an existing skill directory.'

    # 6. Hermes external_dirs awareness: ignores YAML comments, recognizes tilde and slash paths
    $HermesDir = Join-Path $Profile '.hermes'
    New-Item -ItemType Directory -Path $HermesDir -Force | Out-Null
    Remove-Item -LiteralPath (Join-Path $HermesDir 'skills') -Recurse -Force -ErrorAction SilentlyContinue
    $TargetSkillsSlash = (Join-Path $Profile '.agents\skills').Replace('\', '/')
    Set-Content (Join-Path $HermesDir 'config.yaml') "skills:`n  external_dirs:`n    # - $TargetSkillsSlash`n    # - ~/.agents/skills"
    & $SyncScript | Out-Null
    Assert (Test-Path (Join-Path $HermesDir 'skills')) 'Commented-out Hermes external_dirs falsely suppressed skill syncing.'

    Remove-Item -LiteralPath (Join-Path $HermesDir 'skills') -Recurse -Force -ErrorAction SilentlyContinue
    Set-Content (Join-Path $HermesDir 'config.yaml') "skills:`n  external_dirs:`n    - ~/.agents/skills"
    $HermesTildeOut = & $SyncScript *>&1 | Out-String
    Assert ($HermesTildeOut.Contains('Hermes external_dirs already includes')) 'Hermes tilde external_dirs detection failed.'
    Assert (-not (Test-Path (Join-Path $HermesDir 'skills'))) 'Hermes skills directory should not be populated when tilde external_dirs is configured.'

    # 7. Junction-based -Force relink and -Prune broken link cleanup (plus -Check failure detection)
    $LinkProfile = Join-Path $Temp 'link-profile'
    New-Item -ItemType Directory -Path (Join-Path $LinkProfile '.claude\skills') -Force | Out-Null
    $env:USERPROFILE = $LinkProfile
    $env:SYNC_AGENTS_TEST_COPY_FALLBACK = '0'
    try {
        $SavedPath = $env:PATH
        try {
            $env:PATH = "$env:SystemRoot\System32"
            & $SyncScript | Out-Null
            $OldDir = Join-Path $Temp 'old-skill-target'
            $TransientDir = Join-Path $Temp 'transient-skill-target'
            New-Item -ItemType Directory -Path $OldDir, $TransientDir -Force | Out-Null

            $ClaudeDebugSkill = Join-Path $LinkProfile '.claude\skills\systematic-debugging'
            $existingItem = Get-Item -LiteralPath $ClaudeDebugSkill -Force -ErrorAction SilentlyContinue
            if ($existingItem) {
                if ($existingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    $existingItem.Delete()
                } else {
                    Remove-Item -LiteralPath $ClaudeDebugSkill -Recurse -Force
                }
            }
            $junctionCreated = $false
            try {
                New-Item -ItemType Junction -Path $ClaudeDebugSkill -Target $OldDir -ErrorAction Stop | Out-Null
                $BrokenJunction = Join-Path $LinkProfile '.claude\skills\broken-junction'
                New-Item -ItemType Junction -Path $BrokenJunction -Target $TransientDir -ErrorAction Stop | Out-Null
                Remove-Item -LiteralPath $TransientDir -Recurse -Force
                $junctionCreated = $true
            } catch {
                $junctionCreated = $false
            }

            if ($junctionCreated) {
                $global:LASTEXITCODE = 0
                & $SyncScript -Check | Out-Null
                Assert ($LASTEXITCODE -ne 0) '-Check should fail when broken junction exists.'

                $ForceOut = & $SyncScript -Force -Prune *>&1 | Out-String
                Assert ($ForceOut.Contains('[RELINK]')) '-Force did not emit [RELINK] for drifted junction.'
                Assert ($ForceOut.Contains($OldDir)) '-Force [RELINK] log omitted previous target.'
                Assert (-not (Test-Path -LiteralPath $BrokenJunction)) '-Prune did not remove broken junction.'

                $global:LASTEXITCODE = 0
                & $SyncScript -Check | Out-Null
                Assert ($LASTEXITCODE -eq 0) '-Check should pass after -Force -Prune.'

                # Shadowed broken link: plain file in .agents\skills with broken link in downstream target
                $ShadowTransient = Join-Path $Temp 'shadow-transient-target'
                New-Item -ItemType Directory -Path $ShadowTransient -Force | Out-Null
                $PlainSsot = Join-Path $LinkProfile '.agents\skills\plain-non-dir'
                Set-Content -LiteralPath $PlainSsot -Value 'not a skill dir'
                $ShadowBroken = Join-Path $LinkProfile '.claude\skills\plain-non-dir'
                New-Item -ItemType Junction -Path $ShadowBroken -Target $ShadowTransient -ErrorAction Stop | Out-Null
                Remove-Item -LiteralPath $ShadowTransient -Recurse -Force

                $global:LASTEXITCODE = 0
                $ShadowOut = & $SyncScript -Check *>&1 | Out-String
                Assert ($LASTEXITCODE -ne 0) '-Check should fail when downstream broken link shares name with non-directory SSOT entry.'
                Assert ($ShadowOut.Contains('[FAIL] Broken link in target skills:')) 'Expected target broken-link diagnostic when shadowed by non-directory SSOT entry.'

                $ShadowBrokenItem = Get-Item -LiteralPath $ShadowBroken -Force -ErrorAction SilentlyContinue
                if ($ShadowBrokenItem) { $ShadowBrokenItem.Delete() }
                Remove-Item -LiteralPath $PlainSsot -Force -ErrorAction SilentlyContinue

                # Shadowed SSOT broken link: plain file in repo skills\ with broken link in .agents\skills
                $RepoTransient = Join-Path $Temp 'repo-transient-target'
                New-Item -ItemType Directory -Path $RepoTransient -Force | Out-Null
                $PlainRepoEntry = Join-Path $RepoSkills 'repo-plain-file'
                Set-Content -LiteralPath $PlainRepoEntry -Value 'not a skill dir'
                $SsotShadowBroken = Join-Path $LinkProfile '.agents\skills\repo-plain-file'
                New-Item -ItemType Junction -Path $SsotShadowBroken -Target $RepoTransient -ErrorAction Stop | Out-Null
                Remove-Item -LiteralPath $RepoTransient -Recurse -Force

                $global:LASTEXITCODE = 0
                $SsotShadowOut = & $SyncScript -Check *>&1 | Out-String
                Assert ($LASTEXITCODE -ne 0) '-Check should fail when SSOT broken link shares name with non-directory repo entry.'
                Assert ($SsotShadowOut.Contains('[FAIL] Broken link in SSOT skills:')) 'Expected SSOT broken-link diagnostic when shadowed by non-directory repo entry.'

                $SsotShadowItem = Get-Item -LiteralPath $SsotShadowBroken -Force -ErrorAction SilentlyContinue
                if ($SsotShadowItem) { $SsotShadowItem.Delete() }
                Remove-Item -LiteralPath $PlainRepoEntry -Force -ErrorAction SilentlyContinue

                $global:LASTEXITCODE = 0
                & $SyncScript -Check | Out-Null
                Assert ($LASTEXITCODE -eq 0) '-Check should pass after cleaning shadowed broken links.'
            }
        } finally {
            $env:PATH = $SavedPath
        }
    } finally {
        $env:USERPROFILE = $Profile
        $env:SYNC_AGENTS_TEST_COPY_FALLBACK = '1'
    }

    Write-Output 'sync-agents regression tests passed'
} finally {
    $env:USERPROFILE = $OrigUserProfile
    Remove-Item Env:\SYNC_AGENTS_TEST_COPY_FALLBACK -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}
