param(
    [switch]$DryRun,
    [switch]$All,
    [switch]$Force,
    [switch]$Prune
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$RepoMd = Join-Path $RepoRoot "agents\AGENTS.md"
$RepoSkills = Join-Path $RepoRoot "skills"

$AgentsHome = Join-Path $env:USERPROFILE ".agents"
$TargetMd = Join-Path $AgentsHome "AGENTS.md"
$TargetSkills = Join-Path $AgentsHome "skills"

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
        $targets = @($entry.Target)
        if ($targets.Count -eq 0 -or [string]::IsNullOrEmpty([string]$targets[0])) {
            return
        }
        $rawTarget = [string]$targets[0]
        $resolved = if ([IO.Path]::IsPathRooted($rawTarget)) {
            $rawTarget
        } else {
            Join-Path (Split-Path -Parent $entry.FullName) $rawTarget
        }
        if (-not ([System.IO.File]::Exists($resolved) -or [System.IO.Directory]::Exists($resolved))) {
            Write-Output "[PRUNE] Removing broken link: $($entry.FullName)"
            if (-not $DryRun) {
                $entry.Delete()
            }
        }
    }
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
            Write-Output "[RELINK] $Dst -> $Src"
            if (-not $DryRun) { $item.Delete() }
        } else {
            $bak = "$Dst.bak.$(Get-Date -Format 'yyyyMMddHHmmssfff')"
            while (Test-Path -LiteralPath $bak) {
                Start-Sleep -Milliseconds 2
                $bak = "$Dst.bak.$(Get-Date -Format 'yyyyMMddHHmmssfff')"
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
            Write-Output "[RELINK] $dst -> $SrcDir"
            if (-not $DryRun) { $item.Delete() }
            $item = $null
        } elseif (-not (Test-Path -LiteralPath $marker) -or (Get-Content -LiteralPath $marker -Raw).Trim() -ne $SrcDir) {
            Write-Output "[SKIP] Preserving existing skill: $dst"
            return
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
        Get-ChildItem -LiteralPath $TargetSkills -Directory | ForEach-Object { $names[$_.Name] = $true }
    }
    if ($DryRun -and (Test-Path -LiteralPath $RepoSkills)) {
        Get-ChildItem -LiteralPath $RepoSkills -Directory | ForEach-Object { $names[$_.Name] = $true }
    }
    foreach ($name in $names.Keys) { Sync-SkillFolder -SrcDir (Join-Path $TargetSkills $name) -DstDir $TargetDir }
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

$UserHome = $env:USERPROFILE
if (Should-SyncTarget -CheckDir (Join-Path $UserHome ".codex") -BinName "codex") {
    Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".codex\AGENTS.md")
}
if (Should-SyncTarget -CheckDir (Join-Path $UserHome ".claude") -BinName "claude") {
    Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".claude\CLAUDE.md")
    Sync-TargetSkills -TargetDir (Join-Path $UserHome ".claude\skills")
}
if ((Should-SyncTarget -CheckDir (Join-Path $UserHome "AppData\Roaming\opencode") -BinName "opencode") -or (Should-SyncTarget -CheckDir (Join-Path $UserHome ".config\opencode") -BinName "opencode")) {
    Sync-File -Src $TargetMd -Dst (Join-Path $UserHome "AppData\Roaming\opencode\AGENTS.md")
    Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".config\opencode\AGENTS.md")
    Sync-TargetSkills -TargetDir (Join-Path $UserHome ".config\opencode\skills")
}
if (Should-SyncTarget -CheckDir (Join-Path $UserHome ".omo") -BinName "omo") {
    Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".omo\agent\AGENTS.md")
    Sync-TargetSkills -TargetDir (Join-Path $UserHome ".omo\agent\skills")
}
if (Should-SyncTarget -CheckDir (Join-Path $UserHome ".omp") -BinName "omp") {
    Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".omp\agent\AGENTS.md")
    Sync-TargetSkills -TargetDir (Join-Path $UserHome ".omp\agent\skills")
}
if (Should-SyncTarget -CheckDir (Join-Path $UserHome ".gemini") -BinName "gemini") {
    Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".gemini\GEMINI.md")
    Sync-TargetSkills -TargetDir (Join-Path $UserHome ".gemini\skills")
}
if (Should-SyncTarget -CheckDir (Join-Path $UserHome ".hermes") -BinName "hermes") {
    $hermesCfg = Join-Path $UserHome ".hermes\config.yaml"
    $hermesRaw = if (Test-Path -LiteralPath $hermesCfg) { Get-Content -LiteralPath $hermesCfg -Raw } else { "" }
    if ($hermesRaw -and ($hermesRaw.Contains($TargetSkills) -or $hermesRaw.Contains($TargetSkills.Replace('\', '/')))) {
        Write-Output "[OK] Hermes external_dirs already includes $TargetSkills"
    } else {
        Sync-TargetSkills -TargetDir (Join-Path $UserHome ".hermes\skills")
    }
}

if (Test-Path -LiteralPath (Join-Path $UserHome ".cursor")) {
    Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".cursor\rules\global.mdc")
    Sync-TargetSkills -TargetDir (Join-Path $UserHome ".cursor\skills")
}

if (Test-Path -LiteralPath (Join-Path $UserHome ".codeium\windsurf")) {
    Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".codeium\windsurf\memories\global_rules.md")
    Sync-TargetSkills -TargetDir (Join-Path $UserHome ".codeium\windsurf\skills")
}

if (Test-Path -LiteralPath (Join-Path $UserHome ".roo")) {
    Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".roo\rules\global.md")
    Sync-TargetSkills -TargetDir (Join-Path $UserHome ".roo\skills")
}

$ClineDocs = Join-Path $UserHome "Documents\Cline"
if ((Test-Path -LiteralPath $ClineDocs) -or (Test-Path -LiteralPath (Join-Path $UserHome ".cline"))) {
    Sync-File -Src $TargetMd -Dst (Join-Path $ClineDocs "Rules\global.md")
    Sync-TargetSkills -TargetDir (Join-Path $UserHome ".cline\skills")
}

if ((Test-Path -LiteralPath (Join-Path $UserHome ".copilot")) -or (Get-Command "copilot" -ErrorAction SilentlyContinue)) {
    Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".copilot\copilot-instructions.md")
    Sync-TargetSkills -TargetDir (Join-Path $UserHome ".copilot\skills")
}

Write-Output "Done: Windows global AGENTS.md and shared skills synced."
