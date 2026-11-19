# agent-ssot

**Single Source of Truth (SSOT) for AI Coding Agents across macOS, Linux, and Windows.**

[English](./README.md) | [简体中文](./README.zh-CN.md)

`agent-ssot` unifies global engineering rules (`AGENTS.md`) and reusable skills (`skills/`) inside `~/.agents/` and distributes them non-destructively to major CLI and IDE AI coding agents without overwriting each tool's built-in or auto-generated skills.

---

## Core Design Principles

1. **Token-Disciplined Exploration (`Graph -> Paths -> Slices`):** Prioritizes symbol/call-graph queries (`codegraph` / LSP MCP) and bounded Rust CLI searches (`rg`, `fd`, `ast-grep`, `eza`, `dust`, `difft`) over unbounded legacy GNU commands (`find`, `grep`, `tree`, `du`).
2. **Output Compression Compatibility:** Designed to pair cleanly with shell output compressors such as `rtk` by enforcing atomic, low-noise commands and structured failure inspection.
3. **Non-Destructive Item-Level Distribution:** Preserves native directories (`~/.claude/skills`, `~/.omo/agent/skills`, `~/.omp/agent/skills`, etc.) and links shared skills individually, automatically pruning dangling symlinks and backing up existing global instruction files before linking.
4. **Orchestration Neutrality:** Avoids hardcoding vendor-specific tool primitives or conflicting multi-agent schedulers so host orchestrators (`OmO`, `omp`, `agy`, Claude Code, Codex CLI) retain native routing control.

---

## Supported Agents & Target Mappings

| Agent / IDE | Global Instruction Target | Global Skills Target | Distribution Strategy |
| :--- | :--- | :--- | :--- |
| **Codex CLI** | `~/.codex/AGENTS.md` | `~/.agents/skills/` (Native) | File link + Native scan |
| **Claude Code** | `~/.claude/CLAUDE.md` | `~/.claude/skills/<skill>` | File link + Item-level link |
| **OpenCode** | `~/.config/opencode/AGENTS.md` | `~/.config/opencode/skills/<skill>` | File link + Item-level link |
| **Oh My OpenAgent (`OmO`)** | `~/.omo/agent/AGENTS.md` | `~/.omo/agent/skills/<skill>` | File link + Item-level link |
| **Oh My Pi (`omp`)** | `~/.omp/agent/AGENTS.md` | `~/.omp/agent/skills/<skill>` | File link + Item-level link |
| **Antigravity (`agy`) / Gemini CLI** | `~/.gemini/GEMINI.md` | `~/.gemini/skills/<skill>` | File link + Item-level link |
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

> **Note for Windows Users:** Enable **Developer Mode** in Windows Settings (or run PowerShell as Administrator) to create live symlinks/junctions. Otherwise, the script falls back gracefully to file/folder copies.

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

- **Code Search & Navigation:** `ripgrep` (`rg`), `fd`, `ast-grep` (`sg`), `codegraph` (MCP)
- **Diff, Tree & Disk Inspection:** `delta`, `difftastic` (`difft`), `eza`, `dust`, `bat`
- **Shell Output Compression:** `rtk`

---

## License

[MIT](./LICENSE) © ArrisLink
