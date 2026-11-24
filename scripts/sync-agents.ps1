<#
.SYNOPSIS
    Synchronize or verify global AGENTS.md and shared skills across AI coding agents on Windows.
#>
param(
    [switch]$DryRun,
    [switch]$All,
    [switch]$Force,
    [switch]$Prune,
    [switch]$Check
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$RepoMd = Join-Path $RepoRoot "agents\AGENTS.md"
$RepoSkills = Join-Path $RepoRoot "skills"

$AgentsHome = Join-Path $env:USERPROFILE ".agents"
$TargetMd = Join-Path $AgentsHome "AGENTS.md"
$TargetSkills = Join-Path $AgentsHome "skills"

$Script:CheckFailures = 0

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($DryRun) {
            Write-Output "[DRY-RUN] mkdir $Path"
        } else {
            New-Item -ItemType Directory -Force -Path $Path | Out-Null
        }
    }
}

function Should-SyncTarget {
    param([string]$CheckDir, [string]$BinName = "")
    if ($All) { return $true }
    if (Test-Path -LiteralPath $CheckDir) { return $true }
    if ($BinName -and (Get-Command $BinName -ErrorAction SilentlyContinue)) { return $true }
    return $false
}

function Get-ReparseTargetString {
    param($Item)
    $targets = @($Item.Target | Where-Object { $null -ne $_ -and $_ -ne "" })
    if ($targets.Count -gt 0) {
        return [string]$targets[0]
    }
    return "<unknown>"
}

function Test-ReparseTargetMatch {
    param($Item, [string]$Expected)
    $normExpected = $Expected.TrimEnd('\', '/')
    foreach ($t in @($Item.Target)) {
        if ($null -ne $t -and ([string]$t).TrimEnd('\', '/') -eq $normExpected) {
            return $true
        }
    }
    return $false
}

function Test-ReparsePointValid {
    param($Item)
    if (-not ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return $true
    }
    $targets = @($Item.Target)
    if ($targets.Count -eq 0 -or [string]::IsNullOrEmpty([string]$targets[0])) {
        return ([System.IO.File]::Exists($Item.FullName) -or [System.IO.Directory]::Exists($Item.FullName))
    }
    $rawTarget = [string]$targets[0]
    $resolved = if ([IO.Path]::IsPathRooted($rawTarget)) {
        $rawTarget
    } else {
        Join-Path (Split-Path -Parent $Item.FullName) $rawTarget
    }
    return ([System.IO.File]::Exists($resolved) -or [System.IO.Directory]::Exists($resolved))
}

function Remove-BrokenLinks {
    param([string]$Dir)
    $dirItem = Get-Item -LiteralPath $Dir -Force -ErrorAction SilentlyContinue
    if (-not $dirItem -or ($dirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return
    }
    Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $entry = $_
        if (-not ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            return
        }
        if (-not (Test-ReparsePointValid $entry)) {
            Write-Output "[PRUNE] Removing broken link: $($entry.FullName)"
            if (-not $DryRun) {
                $entry.Delete()
            }
        }
    }
}

function Read-CopyMarker {
    param([string]$MarkerPath)
    if (-not (Test-Path -LiteralPath $MarkerPath)) {
        return ""
    }
    $raw = Get-Content -LiteralPath $MarkerPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return ""
    }
    return $raw.Trim()
}

function Test-HermesExternalSkillsDir {
    param([string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return $false
    }
    $candidates = @(
        $TargetSkills.TrimEnd('\', '/'),
        $TargetSkills.Replace('\', '/').TrimEnd('/'),
        '~/.agents/skills',
        '~\.agents\skills'
    )
    foreach ($rawLine in (Get-Content -LiteralPath $ConfigPath -ErrorAction SilentlyContinue)) {
        if ($null -eq $rawLine) { continue }
        $trimmed = $rawLine.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        $code = [regex]::Replace($trimmed, '\s+#.*$', '')
        foreach ($cand in $candidates) {
            $pattern = '(?:^|[\s:\-\[,''"])' + [regex]::Escape($cand) + '[/\\]*(?:$|[\s\],''"])'
            if ($code -match $pattern) {
                return $true
            }
        }
    }
    return $false
}

function Sync-File {
    param([string]$Src, [string]$Dst)
    Ensure-Dir (Split-Path -Parent $Dst)
    $item = Get-Item -LiteralPath $Dst -Force -ErrorAction SilentlyContinue
    if ($item) {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            if (Test-ReparseTargetMatch -Item $item -Expected $Src) {
                return
            }
            if (-not $Force) {
                Write-Output "[SKIP] Preserving existing link: $Dst"
                return
            }
            $oldTarget = Get-ReparseTargetString $item
            Write-Output "[RELINK] $Dst ($oldTarget -> $Src)"
            if (-not $DryRun) { $item.Delete() }
        } else {
            $ts = Get-Date -Format 'yyyyMMddHHmmssfff'
            $bak = "$Dst.bak.$ts"
            $idx = 1
            while (Test-Path -LiteralPath $bak) {
                $bak = "$Dst.bak.$ts.$idx"
                $idx++
            }
            Write-Output "[BACKUP] $Dst -> $bak"
            if (-not $DryRun) { Move-Item -LiteralPath $Dst -Destination $bak }
        }
    }
    if ($DryRun) { Write-Output "[DRY-RUN] link/copy $Src -> $Dst"; return }
    try {
        if ($env:SYNC_AGENTS_TEST_COPY_FALLBACK -eq '1') { throw 'Copy fallback requested' }
        New-Item -ItemType SymbolicLink -Path $Dst -Target $Src -ErrorAction Stop | Out-Null
    } catch { Copy-Item -LiteralPath $Src -Destination $Dst }
}

function Sync-SkillFolder {
    param([string]$SrcDir, [string]$DstDir)
    $name = Split-Path -Leaf $SrcDir
    $dst = Join-Path $DstDir $name
    $marker = Join-Path $DstDir ".$name.agent-ssot-copy"
    $item = Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
    if ($item) {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            if (Test-ReparseTargetMatch -Item $item -Expected $SrcDir) {
                return
            }
            if (-not $Force) {
                Write-Output "[SKIP] Preserving existing link: $dst"
                return
            }
            $oldTarget = Get-ReparseTargetString $item
            Write-Output "[RELINK] $dst ($oldTarget -> $SrcDir)"
            if (-not $DryRun) { $item.Delete() }
            $item = $null
        } else {
            $markerTarget = Read-CopyMarker -MarkerPath $marker
            if (-not $markerTarget -or ($markerTarget.TrimEnd('\', '/') -ne $SrcDir.TrimEnd('\', '/'))) {
                Write-Output "[SKIP] Preserving existing skill: $dst"
                return
            }
        }
    }
    if ($DryRun) { Write-Output "[DRY-RUN] link/copy dir $SrcDir -> $dst"; return }
    if ($item) {
        Copy-Item -Path (Join-Path $SrcDir '*') -Destination $dst -Recurse -Force
        return
    }
    try {
        if ($env:SYNC_AGENTS_TEST_COPY_FALLBACK -eq '1') { throw 'Copy fallback requested' }
        New-Item -ItemType Junction -Path $dst -Target $SrcDir -ErrorAction Stop | Out-Null
    } catch {
        Copy-Item -LiteralPath $SrcDir -Destination $dst -Recurse -Force
        Set-Content -LiteralPath $marker -Value $SrcDir
    }
}

function Sync-TargetSkills {
    param([string]$TargetDir)
    $item = Get-Item -LiteralPath $TargetDir -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        Write-Output "[SKIP] Preserving skills directory link: $TargetDir"
        return
    }
    Ensure-Dir $TargetDir
    if ($Prune) {
        Remove-BrokenLinks -Dir $TargetDir
    }
    $names = @{}
    if (Test-Path -LiteralPath $TargetSkills) {
        Get-ChildItem -LiteralPath $TargetSkills -Directory -Force | Where-Object { Test-ReparsePointValid $_ } | ForEach-Object { $names[$_.Name] = $true }
    }
    if ($DryRun -and (Test-Path -LiteralPath $RepoSkills)) {
        Get-ChildItem -LiteralPath $RepoSkills -Directory | ForEach-Object { $names[$_.Name] = $true }
    }
    foreach ($name in $names.Keys) { Sync-SkillFolder -SrcDir (Join-Path $TargetSkills $name) -DstDir $TargetDir }
}

function Resolve-AltRepoRoot {
    $gitFile = Join-Path $RepoRoot ".git"
    if (-not (Test-Path -LiteralPath $gitFile -PathType Leaf)) {
        return ""
    }
    $firstLine = Get-Content -LiteralPath $gitFile -TotalCount 1 -ErrorAction SilentlyContinue
    if ($firstLine -and ($firstLine -match '^gitdir:\s*(.+?)[/\\]\.git[/\\]worktrees[/\\][^/\\]+$')) {
        return $Matches[1]
    }
    return ""
}

function Test-CheckFile {
    param([string]$Src, [string]$Dst, [string]$AltSrc = "")
    $item = Get-Item -LiteralPath $Dst -Force -ErrorAction SilentlyContinue
    if (-not $item) {
        Write-Output "[FAIL] Missing rule file: $Dst"
        $Script:CheckFailures++
        return
    }
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        if (-not (Test-ReparsePointValid $item)) {
            Write-Output "[FAIL] Broken rule link: $Dst"
            $Script:CheckFailures++
            return
        }
        if ((Test-ReparseTargetMatch -Item $item -Expected $Src) -or ($AltSrc -and (Test-ReparseTargetMatch -Item $item -Expected $AltSrc))) {
            Write-Output "[OK] Linked rule file: $Dst"
        } else {
            $oldTarget = Get-ReparseTargetString $item
            Write-Output "[FAIL] Rule link target drift: $Dst ($oldTarget != $Src)"
            $Script:CheckFailures++
        }
        return
    }
    if (-not [System.IO.File]::Exists($Src)) {
        Write-Output "[FAIL] Missing expected source rule file: $Src"
        $Script:CheckFailures++
        return
    }
    $dstHash = (Get-FileHash -LiteralPath $Dst -Algorithm SHA256).Hash
    $srcHash = (Get-FileHash -LiteralPath $Src -Algorithm SHA256).Hash
    $altMatch = $false
    if ($AltSrc -and [System.IO.File]::Exists($AltSrc)) {
        $altMatch = ($dstHash -eq (Get-FileHash -LiteralPath $AltSrc -Algorithm SHA256).Hash)
    }
    if ($dstHash -eq $srcHash -or $altMatch) {
        Write-Output "[OK] Synced rule file copy: $Dst"
    } else {
        Write-Output "[FAIL] Rule file content drift: $Dst"
        $Script:CheckFailures++
    }
}

function Test-CheckTargetSkills {
    param([string]$TargetDir)
    $dirItem = Get-Item -LiteralPath $TargetDir -Force -ErrorAction SilentlyContinue
    if (-not $dirItem) {
        Write-Output "[FAIL] Missing target skills directory: $TargetDir"
        $Script:CheckFailures++
        return
    }
    if ($dirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        if (Test-ReparsePointValid $dirItem) {
            Write-Output "[OK] Preserved skills directory link: $TargetDir"
        } else {
            Write-Output "[FAIL] Broken skills directory link: $TargetDir"
            $Script:CheckFailures++
        }
        return
    }

    if (Test-Path -LiteralPath $TargetSkills) {
        Get-ChildItem -LiteralPath $TargetSkills -Directory -Force | Where-Object { Test-ReparsePointValid $_ } | ForEach-Object {
            $srcSkill = $_.FullName
            $name = $_.Name
            $dst = Join-Path $TargetDir $name
            $marker = Join-Path $TargetDir ".$name.agent-ssot-copy"
            $dstItem = Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
            if (-not $dstItem) {
                Write-Output "[FAIL] Missing synced skill: $dst"
                $Script:CheckFailures++
                return
            }
            if ($dstItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                if (-not (Test-ReparsePointValid $dstItem)) {
                    Write-Output "[FAIL] Broken target skill link: $dst"
                    $Script:CheckFailures++
                } else {
                    Write-Output "[OK] Target skill link: $dst"
                }
            } elseif (Test-Path -LiteralPath $marker) {
                $markerTarget = Read-CopyMarker -MarkerPath $marker
                if (-not $markerTarget -or ($markerTarget.TrimEnd('\', '/') -ne $srcSkill.TrimEnd('\', '/'))) {
                    Write-Output "[FAIL] Invalid or drifted copy marker: $marker"
                    $Script:CheckFailures++
                } else {
                    Write-Output "[OK] Managed skill copy: $dst"
                }
            } else {
                Write-Output "[OK] Preserved native/private skill: $dst"
            }
        }
    }

    Get-ChildItem -LiteralPath $TargetDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and -not (Test-ReparsePointValid $_)) {
            $ssotCand = Get-Item -LiteralPath (Join-Path $TargetSkills $_.Name) -Force -ErrorAction SilentlyContinue
            $inValidSsot = ($null -ne $ssotCand) -and $ssotCand.PSIsContainer -and (Test-ReparsePointValid $ssotCand)
            if (-not $inValidSsot) {
                Write-Output "[FAIL] Broken link in target skills: $($_.FullName)"
                $Script:CheckFailures++
            }
        }
    }
}

function Apply-OrCheckTarget {
    param([string]$MdDst = "", [string]$SkillsDst = "")
    if ($Check) {
        if ($MdDst) { Test-CheckFile -Src $TargetMd -Dst $MdDst }
        if ($SkillsDst) { Test-CheckTargetSkills -TargetDir $SkillsDst }
    } else {
        if ($MdDst) { Sync-File -Src $TargetMd -Dst $MdDst }
        if ($SkillsDst) { Sync-TargetSkills -TargetDir $SkillsDst }
    }
}

function Sync-AgentTarget {
    param(
        [string]$CheckDir,
        [string]$BinName = "",
        [string]$MdDst = "",
        [string]$SkillsDst = "",
        [switch]$Optional
    )
    $active = if ($Optional) {
        (Test-Path -LiteralPath $CheckDir) -or ($BinName -and (Get-Command $BinName -ErrorAction SilentlyContinue))
    } else {
        Should-SyncTarget -CheckDir $CheckDir -BinName $BinName
    }
    if (-not $active) { return }
    Apply-OrCheckTarget -MdDst $MdDst -SkillsDst $SkillsDst
}

function Invoke-AllTargets {
    $UserHome = $env:USERPROFILE
    Sync-AgentTarget -CheckDir (Join-Path $UserHome ".codex") -BinName "codex" -MdDst (Join-Path $UserHome ".codex\AGENTS.md")
    Sync-AgentTarget -CheckDir (Join-Path $UserHome ".claude") -BinName "claude" -MdDst (Join-Path $UserHome ".claude\CLAUDE.md") -SkillsDst (Join-Path $UserHome ".claude\skills")

    $opencodeRoaming = Join-Path $UserHome "AppData\Roaming\opencode"
    $opencodeConfig = Join-Path $UserHome ".config\opencode"
    $hasOpencodeRoaming = Test-Path -LiteralPath $opencodeRoaming
    $hasOpencodeConfig = Test-Path -LiteralPath $opencodeConfig
    $hasOpencodeBin = [bool](Get-Command "opencode" -ErrorAction SilentlyContinue)

    if ($All) {
        Apply-OrCheckTarget -MdDst (Join-Path $opencodeRoaming "AGENTS.md")
        Apply-OrCheckTarget -MdDst (Join-Path $opencodeConfig "AGENTS.md") -SkillsDst (Join-Path $opencodeConfig "skills")
    } elseif ($hasOpencodeRoaming -or $hasOpencodeConfig) {
        if ($hasOpencodeRoaming) {
            $roamingSkills = if (-not $hasOpencodeConfig) { Join-Path $opencodeRoaming "skills" } else { "" }
            Apply-OrCheckTarget -MdDst (Join-Path $opencodeRoaming "AGENTS.md") -SkillsDst $roamingSkills
        }
        if ($hasOpencodeConfig) {
            Apply-OrCheckTarget -MdDst (Join-Path $opencodeConfig "AGENTS.md") -SkillsDst (Join-Path $opencodeConfig "skills")
        }
    } elseif ($hasOpencodeBin) {
        Apply-OrCheckTarget -MdDst (Join-Path $opencodeConfig "AGENTS.md") -SkillsDst (Join-Path $opencodeConfig "skills")
    }

    Sync-AgentTarget -CheckDir (Join-Path $UserHome ".omo") -BinName "omo" -MdDst (Join-Path $UserHome ".omo\agent\AGENTS.md") -SkillsDst (Join-Path $UserHome ".omo\agent\skills")
    Sync-AgentTarget -CheckDir (Join-Path $UserHome ".omp") -BinName "omp" -MdDst (Join-Path $UserHome ".omp\agent\AGENTS.md") -SkillsDst (Join-Path $UserHome ".omp\agent\skills")
    Sync-AgentTarget -CheckDir (Join-Path $UserHome ".gemini") -BinName "gemini" -MdDst (Join-Path $UserHome ".gemini\GEMINI.md") -SkillsDst (Join-Path $UserHome ".gemini\skills")

    if (Should-SyncTarget -CheckDir (Join-Path $UserHome ".hermes") -BinName "hermes") {
        $hermesCfg = Join-Path $UserHome ".hermes\config.yaml"
        if (Test-HermesExternalSkillsDir -ConfigPath $hermesCfg) {
            Write-Output "[OK] Hermes external_dirs already includes $TargetSkills"
        } elseif ($Check) {
            Test-CheckTargetSkills -TargetDir (Join-Path $UserHome ".hermes\skills")
        } else {
            Sync-TargetSkills -TargetDir (Join-Path $UserHome ".hermes\skills")
        }
    }

    Sync-AgentTarget -CheckDir (Join-Path $UserHome ".cursor") -BinName "cursor" -MdDst (Join-Path $UserHome ".cursor\rules\global.mdc") -SkillsDst (Join-Path $UserHome ".cursor\skills") -Optional
    Sync-AgentTarget -CheckDir (Join-Path $UserHome ".codeium\windsurf") -MdDst (Join-Path $UserHome ".codeium\windsurf\memories\global_rules.md") -SkillsDst (Join-Path $UserHome ".codeium\windsurf\skills") -Optional
    Sync-AgentTarget -CheckDir (Join-Path $UserHome ".roo") -MdDst (Join-Path $UserHome ".roo\rules\global.md") -SkillsDst (Join-Path $UserHome ".roo\skills") -Optional

    $ClineDocs = Join-Path $UserHome "Documents\Cline"
    if ((Test-Path -LiteralPath $ClineDocs) -or (Test-Path -LiteralPath (Join-Path $UserHome ".cline"))) {
        Apply-OrCheckTarget -MdDst (Join-Path $ClineDocs "Rules\global.md") -SkillsDst (Join-Path $UserHome ".cline\skills")
    }

    Sync-AgentTarget -CheckDir (Join-Path $UserHome ".copilot") -BinName "copilot" -MdDst (Join-Path $UserHome ".copilot\copilot-instructions.md") -SkillsDst (Join-Path $UserHome ".copilot\skills") -Optional
}

function Test-CompanionTools {
    foreach ($tool in @('rg', 'fd', 'ast-grep', 'eza', 'dust', 'difft', 'delta', 'bat', 'rtk', 'codegraph')) {
        $cmd = Get-Command $tool -ErrorAction SilentlyContinue
        if ($cmd) {
            Write-Output "[OK] Companion tool ${tool}: $($cmd.Source)"
        } else {
            Write-Output "[WARN] Companion tool missing: $tool"
        }
    }
}

if ($Check) {
    $altRoot = Resolve-AltRepoRoot
    $altMd = if ($altRoot) { Join-Path $altRoot "agents\AGENTS.md" } else { "" }
    $altSkills = if ($altRoot) { Join-Path $altRoot "skills" } else { "" }

    Test-CheckFile -Src $RepoMd -Dst $TargetMd -AltSrc $altMd

    if (-not (Test-Path -LiteralPath $TargetSkills -PathType Container)) {
        Write-Output "[FAIL] Missing SSOT skills directory: $TargetSkills"
        $Script:CheckFailures++
    } else {
        if (Test-Path -LiteralPath $RepoSkills) {
            Get-ChildItem -LiteralPath $RepoSkills -Directory | ForEach-Object {
                $skillName = $_.Name
                $repoSkillDir = $_.FullName
                $altSkillDir = if ($altSkills) { Join-Path $altSkills $skillName } else { "" }
                $ssotEntry = Join-Path $TargetSkills $skillName
                $ssotMarker = Join-Path $TargetSkills ".$skillName.agent-ssot-copy"
                $entryItem = Get-Item -LiteralPath $ssotEntry -Force -ErrorAction SilentlyContinue
                if (-not $entryItem) {
                    Write-Output "[FAIL] Missing SSOT skill entry: $ssotEntry"
                    $Script:CheckFailures++
                    return
                }
                if ($entryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    if (-not (Test-ReparsePointValid $entryItem)) {
                        Write-Output "[FAIL] Broken SSOT skill link: $ssotEntry"
                        $Script:CheckFailures++
                    } elseif ((Test-ReparseTargetMatch -Item $entryItem -Expected $repoSkillDir) -or ($altSkillDir -and (Test-ReparseTargetMatch -Item $entryItem -Expected $altSkillDir))) {
                        Write-Output "[OK] SSOT skill link: $ssotEntry"
                    } else {
                        $oldTarget = Get-ReparseTargetString $entryItem
                        Write-Output "[FAIL] SSOT skill link drift: $ssotEntry ($oldTarget != $repoSkillDir)"
                        $Script:CheckFailures++
                    }
                } elseif (Test-Path -LiteralPath $ssotMarker) {
                    $markerTarget = Read-CopyMarker -MarkerPath $ssotMarker
                    $normMarker = $markerTarget.TrimEnd('\', '/')
                    if (-not $normMarker -or (($normMarker -ne $repoSkillDir.TrimEnd('\', '/')) -and (-not $altSkillDir -or ($normMarker -ne $altSkillDir.TrimEnd('\', '/'))))) {
                        Write-Output "[FAIL] Invalid or drifted SSOT copy marker: $ssotMarker"
                        $Script:CheckFailures++
                    } else {
                        Write-Output "[OK] Managed SSOT skill copy: $ssotEntry"
                    }
                } elseif ($entryItem.PSIsContainer) {
                    Write-Output "[OK] Preserved custom SSOT skill directory: $ssotEntry"
                } else {
                    Write-Output "[FAIL] Invalid non-directory SSOT skill entry: $ssotEntry"
                    $Script:CheckFailures++
                }
            }
        }

        Get-ChildItem -LiteralPath $TargetSkills -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and -not (Test-ReparsePointValid $_)) {
                $inRepo = Test-Path -LiteralPath (Join-Path $RepoSkills $_.Name) -PathType Container
                if (-not $inRepo) {
                    Write-Output "[FAIL] Broken link in SSOT skills: $($_.FullName)"
                    $Script:CheckFailures++
                }
            }
        }
    }

    Invoke-AllTargets
    Test-CompanionTools

    if ($Script:CheckFailures -gt 0) {
        Write-Output "Check failed: $($Script:CheckFailures) SSOT wiring issue(s) found."
        exit 1
    }
    Write-Output "Check passed: Windows SSOT wiring is healthy."
    exit 0
}

Ensure-Dir $TargetSkills
Sync-File -Src $RepoMd -Dst $TargetMd

if (Test-Path -LiteralPath $RepoSkills) {
    Get-ChildItem -LiteralPath $RepoSkills -Directory | ForEach-Object {
        Sync-SkillFolder -SrcDir $_.FullName -DstDir $TargetSkills
    }
}

if ($Prune) {
    Remove-BrokenLinks -Dir $TargetSkills
}

Invoke-AllTargets

Write-Output "Done: Windows global AGENTS.md and shared skills synced."
