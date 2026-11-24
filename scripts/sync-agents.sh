#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=false
SYNC_ALL=false
FORCE_RELINK=false
PRUNE_DANGLING=false
CHECK_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --all)     SYNC_ALL=true ;;
    --force)   FORCE_RELINK=true ;;
    --prune)   PRUNE_DANGLING=true ;;
    --check)   CHECK_ONLY=true ;;
    -h|--help)
      cat <<'EOF'
Usage: sync-agents.sh [--dry-run] [--all] [--force] [--prune] [--check]

Options:
  --dry-run  Preview operations without modifying the filesystem
  --all      Create and populate all core CLI agent targets even if uninstalled
  --force    Repoint existing symlinks when the agent-ssot checkout moved
  --prune    Remove broken symlinks managed under ~/.agents/skills and downstream skills dirs
  --check    Verify SSOT wiring and companion CLI health without modifying the filesystem
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

_script_src="${BASH_SOURCE[0]}"
case "$_script_src" in
  */*) _script_dir="${_script_src%/*}" ;;
  *)   _script_dir="." ;;
esac
SCRIPT_DIR="$(cd "$_script_dir" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_MD="$REPO_ROOT/agents/AGENTS.md"
REPO_SKILLS="$REPO_ROOT/skills"

AGENTS_HOME="$HOME/.agents"
TARGET_MD="$AGENTS_HOME/AGENTS.md"
TARGET_SKILLS="$AGENTS_HOME/skills"

CHECK_FAILURES=0

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

_line_has_path_token() {
  local text=${1%$'\r'}
  local needle=${2%/}
  local rest="$text"
  local prefix suffix last_before first_after tmp

  while [[ "$rest" == *"$needle"* ]]; do
    prefix=${rest%%"$needle"*}
    suffix=${rest#*"$needle"}
    while [[ "$suffix" == /* ]]; do
      suffix=${suffix#/}
    done
    last_before=""
    if [ -n "$prefix" ]; then
      tmp=${prefix%?}
      last_before=${prefix#"$tmp"}
    fi
    first_after=""
    if [ -n "$suffix" ]; then
      tmp=${suffix#?}
      first_after=${suffix%"$tmp"}
    fi
    case "$last_before" in
      ""|" "|$'\t'|":"|"-"|"["|","|"'"|'"')
        case "$first_after" in
          ""|" "|$'\t'|"]"|","|"'"|'"')
            return 0
            ;;
        esac
        ;;
    esac
    rest="$suffix"
  done
  return 1
}

hermes_has_external_skills_dir() {
  local cfg="$1"
  if [ ! -f "$cfg" ]; then
    return 1
  fi
  local target_norm=${TARGET_SKILLS%/}
  local tilde_char='~'
  local tilde_norm="${tilde_char}/.agents/skills"
  local line leading_ws code
  while IFS= read -r line || [ -n "$line" ]; do
    leading_ws=${line%%[![:space:]]*}
    line=${line#"$leading_ws"}
    case "$line" in
      ""|\#*) continue ;;
    esac
    code="$line"
    case "$code" in
      *[[:space:]]\#*) code=${code%%[[:space:]]\#*} ;;
    esac
    if _line_has_path_token "$code" "$target_norm" || _line_has_path_token "$code" "$tilde_norm"; then
      return 0
    fi
  done < "$cfg"
  return 1
}

link_file() {
  local src="$1"
  local dst="$2"
  local dst_dir="${dst%/*}"
  if [ -z "$dst_dir" ]; then
    dst_dir="/"
  fi
  ensure_dir "$dst_dir"

  if [ -e "$dst" ] || [ -L "$dst" ]; then
    if [ -L "$dst" ]; then
      local current
      current="$(readlink "$dst")"
      if [ "$current" = "$src" ]; then
        return
      fi
      if [ "$FORCE_RELINK" = true ]; then
        echo "[RELINK] $dst ($current -> $src)"
        run_cmd ln -sfn "$src" "$dst"
        return
      fi
      echo "[SKIP] Preserving existing non-project target: $dst"
      return
    fi
    if [ -f "$dst" ]; then
      local ts bak idx
      ts="$(date +%Y%m%d%H%M%S)"
      bak="${dst}.bak.${ts}"
      idx=1
      while [ -e "$bak" ] || [ -L "$bak" ]; do
        bak="${dst}.bak.${ts}.${idx}"
        idx=$((idx + 1))
      done
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
  if [ ! -d "$dir" ] || [ -L "$dir" ]; then
    return 0
  fi
  local entry
  for entry in "$dir"/*; do
    if [ ! -L "$entry" ]; then
      continue
    fi
    if [ ! -e "$entry" ]; then
      echo "[PRUNE] Removing broken symlink: $entry"
      run_cmd rm -f "$entry"
    fi
  done
}

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

  local sources=()
  local has_sources=false
  local entry
  if [ -d "$TARGET_SKILLS" ]; then
    for entry in "$TARGET_SKILLS"/*; do
      if [ ! -d "$entry" ]; then
        continue
      fi
      sources+=("$entry")
      has_sources=true
    done
  fi
  if [ "$DRY_RUN" = true ] && [ -d "$REPO_SKILLS" ]; then
    local skill_dir
    for skill_dir in "$REPO_SKILLS"/*; do
      if [ ! -d "$skill_dir" ]; then
        continue
      fi
      sources+=("$TARGET_SKILLS/${skill_dir##*/}")
      has_sources=true
    done
  fi

  if [ "$has_sources" = false ]; then
    return 0
  fi

  local seen=$'\n'
  local src_skill name dst expected current
  for src_skill in "${sources[@]}"; do
    name="${src_skill##*/}"
    if [[ "$seen" == *$'\n'"$name"$'\n'* ]]; then
      continue
    fi
    seen="${seen}${name}"$'\n'
    dst="$target_dir/$name"
    expected="$src_skill"

    if [ -L "$dst" ]; then
      current="$(readlink "$dst")"
      if [ "$current" = "$expected" ]; then
        continue
      fi
      if [ "$FORCE_RELINK" = true ]; then
        echo "[RELINK] $dst ($current -> $expected)"
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

resolve_alt_repo_root() {
  local git_file="$REPO_ROOT/.git"
  if [ ! -f "$git_file" ]; then
    return 0
  fi
  local line gitdir
  if ! IFS= read -r line < "$git_file"; then
    return 0
  fi
  line="${line%$'\r'}"
  case "$line" in
    "gitdir: "*/.git/worktrees/*)
      gitdir="${line#gitdir: }"
      printf '%s\n' "${gitdir%/.git/worktrees/*}"
      ;;
  esac
}

check_linked_file() {
  local src="$1"
  local dst="$2"
  if [ ! -L "$dst" ]; then
    echo "[FAIL] Missing or unlinked target rule file: $dst"
    CHECK_FAILURES=$((CHECK_FAILURES + 1))
    return
  fi
  local actual
  actual="$(readlink "$dst")"
  if [ ! -e "$dst" ]; then
    echo "[FAIL] Broken target rule symlink: $dst -> $actual"
    CHECK_FAILURES=$((CHECK_FAILURES + 1))
  elif [ "$actual" != "$src" ]; then
    echo "[FAIL] Target rule symlink drift: $dst ($actual != $src)"
    CHECK_FAILURES=$((CHECK_FAILURES + 1))
  else
    echo "[OK] Target rule link: $dst -> $actual"
  fi
}

check_skills_entries() {
  local target_dir="$1"
  if [ -L "$target_dir" ]; then
    if [ -d "$target_dir" ]; then
      echo "[OK] Preserved skills directory symlink: $target_dir"
    else
      echo "[FAIL] Broken skills directory symlink: $target_dir"
      CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi
    return
  fi
  if [ ! -d "$target_dir" ]; then
    echo "[FAIL] Missing target skills directory: $target_dir"
    CHECK_FAILURES=$((CHECK_FAILURES + 1))
    return
  fi

  local src_skill name dst actual
  if [ -d "$TARGET_SKILLS" ]; then
    for src_skill in "$TARGET_SKILLS"/*; do
      if [ ! -d "$src_skill" ]; then
        continue
      fi
      name="${src_skill##*/}"
      dst="$target_dir/$name"
      if [ -L "$dst" ]; then
        actual="$(readlink "$dst")"
        if [ ! -e "$dst" ]; then
          echo "[FAIL] Broken target skill symlink: $dst -> $actual"
          CHECK_FAILURES=$((CHECK_FAILURES + 1))
        elif [ "$actual" = "$src_skill" ]; then
          echo "[OK] Target skill link: $dst -> $actual"
        else
          echo "[OK] Preserved custom skill symlink: $dst -> $actual"
        fi
      elif [ -e "$dst" ]; then
        echo "[OK] Preserved native/private skill: $dst"
      else
        echo "[FAIL] Missing synced skill: $dst"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
      fi
    done
  fi

  local entry entry_name
  for entry in "$target_dir"/*; do
    if [ -L "$entry" ] && [ ! -e "$entry" ]; then
      entry_name="${entry##*/}"
      if [ ! -d "$TARGET_SKILLS/$entry_name" ]; then
        echo "[FAIL] Broken symlink in target skills: $entry"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
      fi
    fi
  done
}

apply_or_check_target() {
  local md_dst="$1"
  local skills_dst="${2:-}"
  if [ "$CHECK_ONLY" = true ]; then
    if [ -n "$md_dst" ]; then
      check_linked_file "$TARGET_MD" "$md_dst"
    fi
    if [ -n "$skills_dst" ]; then
      check_skills_entries "$skills_dst"
    fi
  else
    if [ -n "$md_dst" ]; then
      link_file "$TARGET_MD" "$md_dst"
    fi
    if [ -n "$skills_dst" ]; then
      sync_skills_entries "$skills_dst"
    fi
  fi
}

sync_agent_target() {
  local check_dir="$1"
  local bin_name="$2"
  local md_dst="$3"
  local skills_dst="${4:-}"
  if should_sync_target "$check_dir" "$bin_name"; then
    apply_or_check_target "$md_dst" "$skills_dst"
  fi
}

process_all_targets() {
  # Core CLI Agents (smart detection prevents ghost dotfiles for uninstalled/purged agents; pass --all to pre-seed all)
  sync_agent_target "$HOME/.codex" "codex" "$HOME/.codex/AGENTS.md"
  sync_agent_target "$HOME/.claude" "claude" "$HOME/.claude/CLAUDE.md" "$HOME/.claude/skills"
  sync_agent_target "$HOME/.config/opencode" "opencode" "$HOME/.config/opencode/AGENTS.md" "$HOME/.config/opencode/skills"
  sync_agent_target "$HOME/.omo" "omo" "$HOME/.omo/agent/AGENTS.md" "$HOME/.omo/agent/skills"
  sync_agent_target "$HOME/.omp" "omp" "$HOME/.omp/agent/AGENTS.md" "$HOME/.omp/agent/skills"
  sync_agent_target "$HOME/.gemini" "gemini" "$HOME/.gemini/GEMINI.md" "$HOME/.gemini/skills"

  if should_sync_target "$HOME/.hermes" "hermes"; then
    if hermes_has_external_skills_dir "$HOME/.hermes/config.yaml"; then
      echo "[OK] Hermes external_dirs already includes $TARGET_SKILLS"
    elif [ "$CHECK_ONLY" = true ]; then
      check_skills_entries "$HOME/.hermes/skills"
    else
      sync_skills_entries "$HOME/.hermes/skills"
    fi
  fi

  # Optional IDE / Extension Agents
  if [ -d "$HOME/.cursor" ] || command -v cursor >/dev/null 2>&1; then
    apply_or_check_target "$HOME/.cursor/rules/global.mdc" "$HOME/.cursor/skills"
  fi

  if [ -d "$HOME/.codeium/windsurf" ]; then
    apply_or_check_target "$HOME/.codeium/windsurf/memories/global_rules.md" "$HOME/.codeium/windsurf/skills"
  fi

  if [ -d "$HOME/.roo" ]; then
    apply_or_check_target "$HOME/.roo/rules/global.md" "$HOME/.roo/skills"
  fi

  if [ -d "$HOME/Documents/Cline" ] || [ -d "$HOME/.cline" ]; then
    apply_or_check_target "$HOME/Documents/Cline/Rules/global.md" "$HOME/.cline/skills"
  fi

  if [ -d "$HOME/.copilot" ] || command -v copilot >/dev/null 2>&1; then
    apply_or_check_target "$HOME/.copilot/copilot-instructions.md" "$HOME/.copilot/skills"
  fi
}

check_companion_tools() {
  local tool tool_path
  for tool in rg fd ast-grep eza dust difft delta bat rtk codegraph; do
    if tool_path="$(command -v "$tool" 2>/dev/null)"; then
      if [ "$tool" = "ast-grep" ] && [ "$tool_path" = "/usr/bin/sg" ]; then
        echo "[WARN] Companion tool ast-grep resolved to /usr/bin/sg (POSIX group utility)"
      else
        echo "[OK] Companion tool $tool: $tool_path"
      fi
    else
      echo "[WARN] Companion tool missing: $tool"
    fi
  done
}

run_check_mode() {
  local alt_root alt_md alt_skills actual
  alt_root="$(resolve_alt_repo_root)"
  alt_md=""
  alt_skills=""
  if [ -n "$alt_root" ]; then
    alt_md="$alt_root/agents/AGENTS.md"
    alt_skills="$alt_root/skills"
  fi

  if [ ! -L "$TARGET_MD" ]; then
    echo "[FAIL] Missing or unlinked SSOT instruction file: $TARGET_MD"
    CHECK_FAILURES=$((CHECK_FAILURES + 1))
  else
    actual="$(readlink "$TARGET_MD")"
    if [ ! -e "$TARGET_MD" ]; then
      echo "[FAIL] Broken SSOT instruction symlink: $TARGET_MD -> $actual"
      CHECK_FAILURES=$((CHECK_FAILURES + 1))
    elif [ "$actual" = "$REPO_MD" ] || { [ -n "$alt_md" ] && [ "$actual" = "$alt_md" ]; }; then
      echo "[OK] SSOT instruction link: $TARGET_MD -> $actual"
    else
      echo "[FAIL] SSOT instruction link drift: $TARGET_MD ($actual != $REPO_MD)"
      CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi
  fi

  if [ ! -d "$TARGET_SKILLS" ]; then
    echo "[FAIL] Missing SSOT skills directory: $TARGET_SKILLS"
    CHECK_FAILURES=$((CHECK_FAILURES + 1))
  else
    if [ -d "$REPO_SKILLS" ]; then
      local skill_dir skill_name ssot_entry
      for skill_dir in "$REPO_SKILLS"/*; do
        if [ ! -d "$skill_dir" ]; then
          continue
        fi
        skill_name="${skill_dir##*/}"
        ssot_entry="$TARGET_SKILLS/$skill_name"
        if [ -L "$ssot_entry" ]; then
          actual="$(readlink "$ssot_entry")"
          if [ ! -e "$ssot_entry" ]; then
            echo "[FAIL] Broken SSOT skill symlink: $ssot_entry -> $actual"
            CHECK_FAILURES=$((CHECK_FAILURES + 1))
          elif [ "$actual" = "$skill_dir" ] || { [ -n "$alt_skills" ] && [ "$actual" = "$alt_skills/$skill_name" ]; }; then
            echo "[OK] SSOT skill link: $ssot_entry -> $actual"
          else
            echo "[FAIL] SSOT skill link drift: $ssot_entry ($actual != $skill_dir)"
            CHECK_FAILURES=$((CHECK_FAILURES + 1))
          fi
        elif [ -d "$ssot_entry" ]; then
          echo "[OK] Preserved custom SSOT skill directory: $ssot_entry"
        else
          echo "[FAIL] Missing SSOT skill entry: $ssot_entry"
          CHECK_FAILURES=$((CHECK_FAILURES + 1))
        fi
      done
    fi

    local entry entry_name
    for entry in "$TARGET_SKILLS"/*; do
      if [ -L "$entry" ] && [ ! -e "$entry" ]; then
        entry_name="${entry##*/}"
        if [ ! -d "$REPO_SKILLS/$entry_name" ]; then
          echo "[FAIL] Broken symlink in SSOT skills: $entry"
          CHECK_FAILURES=$((CHECK_FAILURES + 1))
        fi
      fi
    done
  fi

  process_all_targets
  check_companion_tools

  if [ "$CHECK_FAILURES" -gt 0 ]; then
    echo "Check failed: $CHECK_FAILURES SSOT wiring issue(s) found." >&2
    exit 1
  fi
  echo "Check passed: SSOT wiring is healthy."
  exit 0
}

if [ "$CHECK_ONLY" = true ]; then
  run_check_mode
fi

ensure_dir "$TARGET_SKILLS"
link_file "$REPO_MD" "$TARGET_MD"

if [ -d "$REPO_SKILLS" ]; then
  for skill_dir in "$REPO_SKILLS"/*; do
    if [ ! -d "$skill_dir" ]; then
      continue
    fi
    skill_name="${skill_dir##*/}"
    link_file_dir="$TARGET_SKILLS/$skill_name"
    if [ -e "$link_file_dir" ] || [ -L "$link_file_dir" ]; then
      if [ -L "$link_file_dir" ]; then
        current_ssot="$(readlink "$link_file_dir")"
        if [ "$current_ssot" = "$skill_dir" ]; then
          continue
        fi
        if [ "$FORCE_RELINK" = true ]; then
          echo "[RELINK-SSOT] $link_file_dir ($current_ssot -> $skill_dir)"
          run_cmd ln -sfn "$skill_dir" "$link_file_dir"
          continue
        fi
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

process_all_targets

echo "Done: Global AGENTS.md and shared skills synced."
