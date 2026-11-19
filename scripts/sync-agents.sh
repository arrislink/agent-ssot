#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_MD="$REPO_ROOT/agents/AGENTS.md"
REPO_SKILLS="$REPO_ROOT/skills"

AGENTS_HOME="$HOME/.agents"
TARGET_MD="$AGENTS_HOME/AGENTS.md"
TARGET_SKILLS="$AGENTS_HOME/skills"

run_cmd() {
  if [ "$DRY_RUN" = true ]; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

ensure_dir() {
  local d="$1"
  if [ ! -d "$d" ]; then
    run_cmd mkdir -p "$d"
  fi
}

link_file() {
  local src="$1"
  local dst="$2"
  ensure_dir "$(dirname "$dst")"

  if [ -e "$dst" ] || [ -L "$dst" ]; then
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
      return
    fi
    if [ -f "$dst" ] && [ ! -L "$dst" ]; then
      local bak="${dst}.bak.$(date +%Y%m%d%H%M%S)"
      echo "[BACKUP] $dst -> $bak"
      run_cmd mv "$dst" "$bak"
    else
      echo "[SKIP] Preserving existing non-project target: $dst"
      return
    fi
  fi
  run_cmd ln -s "$src" "$dst"
}

ensure_dir "$TARGET_SKILLS"
link_file "$REPO_MD" "$TARGET_MD"

if [ -d "$REPO_SKILLS" ]; then
  for skill_dir in "$REPO_SKILLS"/*; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    link_file_dir="$TARGET_SKILLS/$skill_name"
    if [ -e "$link_file_dir" ] || [ -L "$link_file_dir" ]; then
      if [ -L "$link_file_dir" ] && [ "$(readlink "$link_file_dir")" = "$skill_dir" ]; then
        continue
      fi
      echo "[SKIP-SSOT] Preserving existing skill entry: $link_file_dir"
    else
      run_cmd ln -s "$skill_dir" "$link_file_dir"
    fi
  done
fi

sync_skills_entries() {
  local target_dir="$1"

  if [ -L "$target_dir" ]; then
    local target
    target="$(readlink "$target_dir")"
    if [ "$target" = "$TARGET_SKILLS" ]; then
      echo "[SKIP] Preserving skills directory symlink: $target_dir"
      return
    fi
    echo "[SKIP] Preserving non-project skills directory symlink: $target_dir"
    return
  fi
  ensure_dir "$target_dir"

  local sources=("$TARGET_SKILLS"/*)
  if [ "$DRY_RUN" = true ]; then
    for skill_dir in "$REPO_SKILLS"/*; do
      [ -d "$skill_dir" ] || continue
      sources+=("$TARGET_SKILLS/$(basename "$skill_dir")")
    done
  fi
  for src_skill in "${sources[@]}"; do
    [ -e "$src_skill" ] || [ -L "$src_skill" ] || [ "$DRY_RUN" = true ] && [ "${src_skill##*/}" != '*' ] || continue
    local name dst expected
    name="$(basename "$src_skill")"
    dst="$target_dir/$name"
    expected="$src_skill"

    if [ -L "$dst" ]; then
      local current
      current="$(readlink "$dst")"
      if [ "$current" = "$expected" ]; then
        continue
      fi
      echo "[SKIP] Preserving non-project symlink: $dst"
    elif [ -e "$dst" ]; then
      echo "[SKIP] Preserving existing native/private skill: $dst"
    else
      run_cmd ln -s "$expected" "$dst"
    fi
  done
}


# Core CLI Agents
link_file "$TARGET_MD" "$HOME/.codex/AGENTS.md"
link_file "$TARGET_MD" "$HOME/.claude/CLAUDE.md"
link_file "$TARGET_MD" "$HOME/.config/opencode/AGENTS.md"
link_file "$TARGET_MD" "$HOME/.omo/agent/AGENTS.md"
link_file "$TARGET_MD" "$HOME/.omp/agent/AGENTS.md"
link_file "$TARGET_MD" "$HOME/.gemini/GEMINI.md"

sync_skills_entries "$HOME/.claude/skills"
sync_skills_entries "$HOME/.config/opencode/skills"
sync_skills_entries "$HOME/.omo/agent/skills"
sync_skills_entries "$HOME/.omp/agent/skills"
sync_skills_entries "$HOME/.gemini/skills"

# Optional IDE / Extension Agents
if [ -d "$HOME/.cursor" ] || command -v cursor >/dev/null 2>&1; then
  link_file "$TARGET_MD" "$HOME/.cursor/rules/global.mdc"
  sync_skills_entries "$HOME/.cursor/skills"
fi

if [ -d "$HOME/.codeium/windsurf" ]; then
  link_file "$TARGET_MD" "$HOME/.codeium/windsurf/memories/global_rules.md"
  sync_skills_entries "$HOME/.codeium/windsurf/skills"
fi

if [ -d "$HOME/.roo" ]; then
  link_file "$TARGET_MD" "$HOME/.roo/rules/global.md"
  sync_skills_entries "$HOME/.roo/skills"
fi

if [ -d "$HOME/Documents/Cline" ] || [ -d "$HOME/.cline" ]; then
  link_file "$TARGET_MD" "$HOME/Documents/Cline/Rules/global.md"
  sync_skills_entries "$HOME/.cline/skills"
fi

if [ -d "$HOME/.copilot" ] || command -v gh >/dev/null 2>&1; then
  link_file "$TARGET_MD" "$HOME/.copilot/copilot-instructions.md"
  sync_skills_entries "$HOME/.copilot/skills"
fi

echo "Done: Global AGENTS.md and shared skills synced."
