# Global Engineering & Tooling Policy

## 1. Progressive Code Exploration (Token Discipline)
Follow a strict **Graph → Paths → Slices** funnel to minimize context consumption:
1. **Symbol & Graph First:** When code-graph or LSP/symbol MCP tools (e.g., `codegraph`) are available, query definitions, references, and call chains **before** running filesystem searches.
2. **Native Search Tools Next:** Prefer the host agent's built-in file/content search tools over spawning raw shell subshells for simple lookups.
3. **Paths Before Content:** Narrow down candidate files first (`fd` or `rg -l`). Never dump unbounded full-repo matches into context.
4. **Slice Reads Only:** Read targeted line ranges (`sed -n 'start,endp'` or `bat -r start:end --style=plain`) rather than printing entire large files.

## 2. Rust CLI Replacements (When Using Shell)
When executing shell commands for exploration or inspection, prefer modern Rust equivalents over legacy GNU tools (`find`, `grep`, `tree`, `du`, `diff`) with bounded output:
- **File Discovery (`find` -> `fd`):** `fd -e <ext> <pattern>` or `fd -t f <name>` (respects `.gitignore` automatically).
- **Text Search (`grep` -> `rg`):** Always cap output: `rg -n --max-count 20 "<pattern>" <path>` or `rg -l "<pattern>"`.
- **AST / Structural Search:** Use `ast-grep` (always invoke as `ast-grep`, **never** `sg` — `/usr/bin/sg` on Linux is the POSIX group-switching utility) for function signatures, call sites, and syntax-aware refactoring instead of fragile regexes: `ast-grep --pattern '<pattern>' --lang <lang>`.
- **Directory & Disk (`tree`/`du` -> `eza`/`dust`):** `eza --tree --level=2 --git-ignore --icons=never` and `dust -d 2`.
- **Syntax Diff (`diff` -> `difft`/`delta`):** Prefer `difft` or `git diff` for reviewing structural changes.
- **Clean Fallback:** If a Rust binary is unavailable (`command -v <tool>` fails) in a minimal container or remote host, fall back immediately to standard POSIX tools with `--exclude-dir={.git,node_modules,vendor}` without retrying the missing binary.

## 3. Shell Output & Compression Compatibility
- Keep shell commands atomic and quiet. Avoid verbose flags (`-v`, `--debug`) unless diagnosing a specific failure.
- Assume shell output may pass through output compressors (such as `rtk`); inspect exact failure lines rather than re-running identical noisy commands.

## 4. Workflow & Quality Guardrails
- **Task Proportionality:** For single-file edits, config tweaks, or explicit one-step commands, execute directly and run minimal verification—do not invoke heavy multi-step planning ceremonies.
- **Root-Cause Debugging:** Never apply speculative fixes. Reproduce the issue, trace the root cause via logs/call graph, apply the minimal fix, and verify.
- **Evidence-Based Completion:** Never claim a task, build, or bugfix is complete without running actual verification commands (tests, typecheck, build, or lint) and confirming exit status `0`.
- **Orchestration Boundary:** Respect the host agent's native planning, delegation, and subagent mechanisms. Do not override native agent routing with external subagent workflows.
- **Shared Skills:** Check available skills when encountering specialized workflows (e.g., debugging, spec-driven planning, cloud/K8s ops) and follow progressive disclosure rules.
