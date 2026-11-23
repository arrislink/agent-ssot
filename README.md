# agent-ssot

**Single Source of Truth (SSOT) for AI Coding Agents across macOS, Linux, and Windows.**

[English](./README.md) | [简体中文](./README.zh-CN.md)

`agent-ssot` unifies global engineering rules (`AGENTS.md`) and reusable skills (`skills/`) inside `~/.agents/` and distributes them non-destructively to major CLI and IDE AI coding agents without overwriting each tool's built-in or auto-generated skills.

---

## Core Design Principles

1. **Token-Disciplined Exploration (`Graph -> Paths -> Slices`):** Prioritizes symbol/call-graph queries (`codegraph` / LSP MCP) and bounded Rust CLI searches (`rg`, `fd`, `ast-grep`, `eza`, `dust`, `difft`) over unbounded legacy GNU commands (`find`, `grep`, `tree`, `du`).
2. **Output Compression Compatibility:** Designed to pair cleanly with shell output compressors such as `rtk` by enforcing atomic, low-noise commands and structured failure inspection.
3. **Conservative Item-Level Distribution:** Preserves existing skills directories and unrelated links, including dangling links. Conflicting entries are skipped; existing instruction files are backed up before linking.
4. **Orchestration Neutrality:** Avoids hardcoding vendor-specific tool primitives or conflicting multi-agent schedulers so host orchestrators (`OmO`, `omp`, `agy`, Claude Code, Codex CLI) retain native routing control.

---

## Supported Agents & Target Mappings

| Agent / IDE | Global Instruction Target | Global Skills Target | Distribution Strategy |
| :--- | :--- | :--- | :--- |
| **Codex CLI** *(Auto-detected)* | `~/.codex/AGENTS.md` | `~/.agents/skills/` (Native) | File link + Native scan |
| **Claude Code** *(Auto-detected)* | `~/.claude/CLAUDE.md` | `~/.claude/skills/<skill>` | File link + Item-level link |
| **OpenCode** *(Auto-detected)* | `~/.config/opencode/AGENTS.md` | `~/.config/opencode/skills/<skill>` | File link + Item-level link |
| **Oh My OpenAgent (`OmO`)** *(Auto-detected)* | `~/.omo/agent/AGENTS.md` | `~/.omo/agent/skills/<skill>` | File link + Item-level link |
| **Oh My Pi (`omp`)** *(Auto-detected)* | `~/.omp/agent/AGENTS.md` (+ `~/.agents/AGENTS.md` native) | `~/.omp/agent/skills/<skill>` (+ `~/.agents/skills/` native) | File link + Item-level link |
| **Hermes Agent** *(Auto-detected)* | `skills.external_dirs` / `agent.environment_hint` | `~/.agents/skills/` (`external_dirs`) or `~/.hermes/skills/<skill>` | Native `external_dirs` or Item-level link |
| **Antigravity (`agy`) / Gemini CLI** *(Auto-detected)* | `~/.gemini/GEMINI.md` | `~/.gemini/skills/<skill>` | File link + Item-level link |
| **Cursor** *(Auto-detected)* | `~/.cursor/rules/global.mdc` | `~/.cursor/skills/<skill>` | File link + Item-level link |
| **Windsurf** *(Auto-detected)* | `~/.codeium/windsurf/memories/global_rules.md` | `~/.codeium/windsurf/skills/<skill>` | File link + Item-level link |
| **Roo Code / Cline** *(Auto-detected)* | `~/.roo/rules/global.md` / `~/Documents/Cline/Rules/global.md` | `~/.roo/skills/<skill>` / `~/.cline/skills/<skill>` | File link + Item-level link |
| **GitHub Copilot CLI** *(Auto-detected)* | `~/.copilot/copilot-instructions.md` | `~/.copilot/skills/<skill>` | File link + Item-level link |

---

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/arrislink/agent-ssot.git
cd agent-ssot
```

### 2. Sync on macOS / Linux

Preview changes first with `--dry-run`, then execute:

```bash
chmod +x scripts/sync-agents.sh
./scripts/sync-agents.sh --dry-run
./scripts/sync-agents.sh
```

### 3. Sync on Windows (PowerShell)

Preview changes first with `-DryRun`, then execute:

```powershell
.\scripts\sync-agents.ps1 -DryRun
.\scripts\sync-agents.ps1
```

> **Windows:** Enable Developer Mode (or run PowerShell as Administrator) for links. When a junction cannot be created, a managed copy is refreshed on subsequent runs; files removed upstream are not automatically deleted from that copy. Existing unmarked directories and links are preserved. File-copy fallback creates a backup before each subsequent instruction-file refresh.

An existing skills-directory symlink is preserved and skipped rather than migrated. Inspect `[SKIP]` messages to identify integrations that were not updated. The mappings above describe intended locations; actual discovery varies by agent and version and has not been independently verified for every product.

Run the isolated regression checks with `bash tests/test-sync-agents.sh` on macOS/Linux or `pwsh -File tests/test-sync-agents.ps1` on Windows. CI runs these checks on all three platforms.

Verification on 2026-11-19: `/bin/bash -n scripts/sync-agents.sh` and `/bin/bash tests/test-sync-agents.sh` passed on macOS. The PowerShell tests were not run locally because `pwsh` was unavailable; the CI workflow has been added but its results have not been verified.

---

## Repository Structure

```text
agent-ssot/
├── agents/
│   └── AGENTS.md                 # Global engineering & CLI policy (SSOT)
├── skills/                       # Cross-agent shared skills pool
│   ├── systematic-debugging/
│   │   └── SKILL.md
│   └── verification-before-completion/
│       └── SKILL.md
├── scripts/
│   ├── sync-agents.sh            # macOS / Linux sync script
│   └── sync-agents.ps1           # Windows PowerShell sync script
├── README.md
└── README.zh-CN.md
```

---

## Recommended Companion Tooling

- **Code Search & Navigation:** `ripgrep` (`rg`), `fd`, `ast-grep` (invoke as `ast-grep`, never `sg` on Linux due to `/usr/bin/sg`), `codegraph` (MCP)
- **Diff, Tree & Disk Inspection:** `delta`, `difftastic` (`difft`), `eza`, `dust`, `bat`
- **Shell Output Compression:** `rtk`

---

## License

[MIT](./LICENSE) © ArrisLink
