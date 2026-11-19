param(
    [switch]$DryRun
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
            Write-Host "[DRY-RUN] mkdir $Path"
        } else {
            New-Item -ItemType Directory -Force -Path $Path | Out-Null
        }
    }
}

function Sync-File {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path -LiteralPath $Src)) { return }
    Ensure-Dir (Split-Path -Parent $Dst)

    if ((Test-Path -LiteralPath $Dst) -and (-not ((Get-Item -LiteralPath $Dst).Attributes -band [System.IO.FileAttributes]::ReparsePoint))) {
        $Stamp = Get-Date -Format "yyyyMMddHHmmss"
        $Bak = "$Dst.bak.$Stamp"
        Write-Host "[BACKUP] $Dst -> $Bak"
        if (-not $DryRun) {
            Move-Item -LiteralPath $Dst -Destination $Bak -Force
        }
    }

    if ($DryRun) {
        Write-Host "[DRY-RUN] link/copy $Src -> $Dst"
        return
    }

    if (Test-Path -LiteralPath $Dst) {
        Remove-Item -LiteralPath $Dst -Force -Recurse
    }

    try {
        New-Item -ItemType SymbolicLink -Path $Dst -Target $Src -ErrorAction Stop | Out-Null
    } catch {
        Copy-Item -LiteralPath $Src -Destination $Dst -Force
    }
}

function Sync-SkillFolder {
    param([string]$SrcDir, [string]$DstDir)
    $Name = Split-Path -Leaf $SrcDir
    $Dst = Join-Path $DstDir $Name

    if ((Test-Path -LiteralPath $Dst) -and (-not ((Get-Item -LiteralPath $Dst).Attributes -band [System.IO.FileAttributes]::ReparsePoint))) {
        Write-Host "[SKIP] Preserving existing skill directory: $Dst"
        return
    }

    if ($DryRun) {
        Write-Host "[DRY-RUN] link/copy dir $SrcDir -> $Dst"
        return
    }

    if (Test-Path -LiteralPath $Dst) {
        Remove-Item -LiteralPath $Dst -Force -Recurse
    }

    try {
        New-Item -ItemType Junction -Path $Dst -Target $SrcDir -ErrorAction Stop | Out-Null
    } catch {
        Copy-Item -LiteralPath $SrcDir -Destination $Dst -Recurse -Force
    }
}

function Sync-TargetSkills {
    param([string]$TargetDir)
    Ensure-Dir $TargetDir
    if (-not (Test-Path -LiteralPath $TargetSkills)) { return }

    Get-ChildItem -LiteralPath $TargetSkills -Directory | ForEach-Object {
        Sync-SkillFolder -SrcDir $_.FullName -DstDir $TargetDir
    }
}

Ensure-Dir $TargetSkills
Sync-File -Src $RepoMd -Dst $TargetMd

if (Test-Path -LiteralPath $RepoSkills) {
    Get-ChildItem -LiteralPath $RepoSkills -Directory | ForEach-Object {
        Sync-SkillFolder -SrcDir $_.FullName -DstDir $TargetSkills
    }
}

$UserHome = $env:USERPROFILE
Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".codex\AGENTS.md")
Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".claude\CLAUDE.md")
Sync-File -Src $TargetMd -Dst (Join-Path $UserHome "AppData\Roaming\opencode\AGENTS.md")
Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".config\opencode\AGENTS.md")
Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".omo\agent\AGENTS.md")
Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".omp\agent\AGENTS.md")
Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".gemini\GEMINI.md")

Sync-TargetSkills -TargetDir (Join-Path $UserHome ".claude\skills")
Sync-TargetSkills -TargetDir (Join-Path $UserHome ".config\opencode\skills")
Sync-TargetSkills -TargetDir (Join-Path $UserHome ".omo\agent\skills")
Sync-TargetSkills -TargetDir (Join-Path $UserHome ".omp\agent\skills")
Sync-TargetSkills -TargetDir (Join-Path $UserHome ".gemini\skills")

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

if (Test-Path -LiteralPath (Join-Path $UserHome ".copilot")) {
    Sync-File -Src $TargetMd -Dst (Join-Path $UserHome ".copilot\copilot-instructions.md")
    Sync-TargetSkills -TargetDir (Join-Path $UserHome ".copilot\skills")
}

Write-Host "Done: Windows global AGENTS.md and shared skills synced."
