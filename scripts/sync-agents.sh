#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=false
SYNC_ALL=false
FORCE_RELINK=false
PRUNE_DANGLING=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --all)     SYNC_ALL=true ;;
    --force)   FORCE_RELINK=true ;;
    --prune)   PRUNE_DANGLING=true ;;
    -h|--help)
      cat <<'EOF'
Usage: sync-agents.sh [--dry-run] [--all] [--force] [--prune]

Options:
  --dry-run  Preview operations without modifying the filesystem
  --all      Create and populate all core CLI agent targets even if uninstalled
  --force    Repoint existing symlinks when the agent-ssot checkout moved
  --prune    Remove broken symlinks managed under ~/.agents/skills and downstream skills dirs
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

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

should_sync_target() {
  local check_dir="$1"
  local bin_name="${2:-}"
  if [ "$SYNC_ALL" = true ]; then
    return 0
  fi
  if [ -d "$check_dir" ] || [ -L "$check_dir" ]; then
    return 0
  fi
  if [ -n "$bin_name" ] && command -v "$bin_name" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

link_file() {
  local src="$1"
  local dst="$2"
  ensure_dir "$(dirname "$dst")"

  if [ -e "$dst" ] || [ -L "$dst" ]; then
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
      return
    fi
    if [ -L "$dst" ] && [ "$FORCE_RELINK" = true ]; then
      echo "[RELINK] $dst -> $src"
      run_cmd ln -sfn "$src" "$dst"
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

prune_broken_links() {
  local dir="$1"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  for entry in "$dir"/*; do
    [ -L "$entry" ] || continue
    if [ ! -e "$entry" ]; then
      echo "[PRUNE] Removing broken symlink: $entry"
      run_cmd rm -f "$entry"
    fi
  done
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
      if [ -L "$link_file_dir" ] && [ "$FORCE_RELINK" = true ]; then
        echo "[RELINK-SSOT] $link_file_dir -> $skill_dir"
        run_cmd ln -sfn "$skill_dir" "$link_file_dir"
        continue
      fi
      echo "[SKIP-SSOT] Preserving existing skill entry: $link_file_dir"
    else
      run_cmd ln -s "$skill_dir" "$link_file_dir"
    fi
  done
fi

if [ "$PRUNE_DANGLING" = true ]; then
  prune_broken_links "$TARGET_SKILLS"
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

  if [ "$PRUNE_DANGLING" = true ]; then
    prune_broken_links "$target_dir"
  fi

  local sources=("$TARGET_SKILLS"/*)
  if [ "$DRY_RUN" = true ]; then
    for skill_dir in "$REPO_SKILLS"/*; do
      [ -d "$skill_dir" ] || continue
      sources+=("$TARGET_SKILLS/$(basename "$skill_dir")")
    done
  fi
  local seen=" "
  for src_skill in "${sources[@]}"; do
    [ -e "$src_skill" ] || [ -L "$src_skill" ] || [ "$DRY_RUN" = true ] && [ "${src_skill##*/}" != '*' ] || continue
    local name dst expected
    name="$(basename "$src_skill")"
    case "$seen" in
      *" $name "*) continue ;;
    esac
    seen="$seen$name "
    dst="$target_dir/$name"
    expected="$src_skill"

    if [ -L "$dst" ]; then
      local current
      current="$(readlink "$dst")"
      if [ "$current" = "$expected" ]; then
        continue
      fi
      if [ "$FORCE_RELINK" = true ]; then
        echo "[RELINK] $dst -> $expected"
        run_cmd ln -sfn "$expected" "$dst"
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

# Core CLI Agents (smart detection prevents ghost dotfiles for uninstalled/purged agents; pass --all to pre-seed all)
if should_sync_target "$HOME/.codex" "codex"; then
  link_file "$TARGET_MD" "$HOME/.codex/AGENTS.md"
fi

if should_sync_target "$HOME/.claude" "claude"; then
  link_file "$TARGET_MD" "$HOME/.claude/CLAUDE.md"
  sync_skills_entries "$HOME/.claude/skills"
fi

if should_sync_target "$HOME/.config/opencode" "opencode"; then
  link_file "$TARGET_MD" "$HOME/.config/opencode/AGENTS.md"
  sync_skills_entries "$HOME/.config/opencode/skills"
fi

if should_sync_target "$HOME/.omo" "omo"; then
  link_file "$TARGET_MD" "$HOME/.omo/agent/AGENTS.md"
  sync_skills_entries "$HOME/.omo/agent/skills"
fi

if should_sync_target "$HOME/.omp" "omp"; then
  link_file "$TARGET_MD" "$HOME/.omp/agent/AGENTS.md"
  sync_skills_entries "$HOME/.omp/agent/skills"
fi

if should_sync_target "$HOME/.gemini" "gemini"; then
  link_file "$TARGET_MD" "$HOME/.gemini/GEMINI.md"
  sync_skills_entries "$HOME/.gemini/skills"
fi

if should_sync_target "$HOME/.hermes" "hermes"; then
  if [ -f "$HOME/.hermes/config.yaml" ] && grep -Fq "$TARGET_SKILLS" "$HOME/.hermes/config.yaml" 2>/dev/null; then
    echo "[OK] Hermes external_dirs already includes $TARGET_SKILLS"
  else
    sync_skills_entries "$HOME/.hermes/skills"
  fi
fi

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

if [ -d "$HOME/.copilot" ] || command -v copilot >/dev/null 2>&1; then
  link_file "$TARGET_MD" "$HOME/.copilot/copilot-instructions.md"
  sync_skills_entries "$HOME/.copilot/skills"
fi

echo "Done: Global AGENTS.md and shared skills synced."
