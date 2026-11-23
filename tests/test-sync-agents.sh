#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync-agents.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_link_to() {
  local link="$1" expected="$2" actual
  [ -L "$link" ] || fail "expected symlink: $link"
  actual="$(readlink "$link")"
  [ "$actual" = "$expected" ] || fail "$link points to '$actual', expected '$expected'"
}

# 1. Dry-run with --all from an empty HOME enumerates all source skills and integration targets.
HOME="$TMP_ROOT/dry-home" mkdir -p "$TMP_ROOT/dry-home"
dry_output="$(HOME="$TMP_ROOT/dry-home" bash "$SYNC_SCRIPT" --dry-run --all)"
for skill_path in "$REPO_ROOT"/skills/*; do
  [ -d "$skill_path" ] || continue
  skill="$(basename "$skill_path")"
  [[ "$dry_output" == *"$TMP_ROOT/dry-home/.agents/skills/$skill"* ]] || fail "dry-run omitted primary skill $skill"
  [[ "$dry_output" == *"$TMP_ROOT/dry-home/.claude/skills/$skill"* ]] || fail "dry-run omitted downstream skill $skill"
done

# 2. Smart detection: empty HOME with sanitized PATH creates ~/.agents only, no ghost CLI dirs.
HOME="$TMP_ROOT/smart-home" mkdir -p "$TMP_ROOT/smart-home/.omp/agent"
PATH="/usr/bin:/bin" HOME="$TMP_ROOT/smart-home" bash "$SYNC_SCRIPT" >/dev/null
assert_link_to "$TMP_ROOT/smart-home/.agents/AGENTS.md" "$REPO_ROOT/agents/AGENTS.md"
assert_link_to "$TMP_ROOT/smart-home/.omp/agent/AGENTS.md" "$TMP_ROOT/smart-home/.agents/AGENTS.md"
[ ! -e "$TMP_ROOT/smart-home/.omo" ] || fail "ghost .omo directory should not be created"
[ ! -e "$TMP_ROOT/smart-home/.config/opencode" ] || fail "ghost .config/opencode directory should not be created"

# 3. Existing skill container symlinks are preserved; syncing does not replace directories.
private_target="$TMP_ROOT/private-skills"
mkdir -p "$private_target/private-only"
ln -s "$private_target" "$TMP_ROOT/linked-skills"
HOME="$TMP_ROOT/home-container" mkdir -p "$TMP_ROOT/home-container/.claude"
ln -s "$private_target" "$TMP_ROOT/home-container/.claude/skills"
HOME="$TMP_ROOT/home-container" bash "$SYNC_SCRIPT" >/dev/null
assert_link_to "$TMP_ROOT/home-container/.claude/skills" "$private_target"
[ -d "$private_target/private-only" ] || fail "private skill was lost"

# 4. Non-project links (including dangling links) are preserved by default, while --prune cleans broken links.
HOME="$TMP_ROOT/home-entries" mkdir -p "$TMP_ROOT/home-entries/.claude/skills"
mkdir -p "$TMP_ROOT/home-entries/.agents/skills"
ln -s "$private_target/private-only" "$TMP_ROOT/home-entries/.claude/skills/private"
ln -s "$TMP_ROOT/nonexistent-target" "$TMP_ROOT/home-entries/.claude/skills/dangling"
printf 'native skill\n' > "$TMP_ROOT/home-entries/.claude/skills/native"
HOME="$TMP_ROOT/home-entries" bash "$SYNC_SCRIPT" >/dev/null
assert_link_to "$TMP_ROOT/home-entries/.claude/skills/private" "$private_target/private-only"
assert_link_to "$TMP_ROOT/home-entries/.claude/skills/dangling" "$TMP_ROOT/nonexistent-target"
[ "$(cat "$TMP_ROOT/home-entries/.claude/skills/native")" = 'native skill' ] || fail 'native skill changed'
HOME="$TMP_ROOT/home-entries" bash "$SYNC_SCRIPT" --prune >/dev/null
[ ! -L "$TMP_ROOT/home-entries/.claude/skills/dangling" ] || fail '--prune did not remove broken symlink'
assert_link_to "$TMP_ROOT/home-entries/.claude/skills/private" "$private_target/private-only"

# 5. Repeated runs are safe; --force repoints moved symlinks.
HOME="$TMP_ROOT/home-repeat" mkdir -p "$TMP_ROOT/home-repeat/.claude"
HOME="$TMP_ROOT/home-repeat" bash "$SYNC_SCRIPT" >/dev/null
HOME="$TMP_ROOT/home-repeat" bash "$SYNC_SCRIPT" >/dev/null
for skill_path in "$REPO_ROOT"/skills/*; do
  [ -d "$skill_path" ] || continue
  skill="$(basename "$skill_path")"
  assert_link_to "$TMP_ROOT/home-repeat/.claude/skills/$skill" "$TMP_ROOT/home-repeat/.agents/skills/$skill"
done
ln -sfn "/old/moved/AGENTS.md" "$TMP_ROOT/home-repeat/.claude/CLAUDE.md"
HOME="$TMP_ROOT/home-repeat" bash "$SYNC_SCRIPT" --force >/dev/null
assert_link_to "$TMP_ROOT/home-repeat/.claude/CLAUDE.md" "$TMP_ROOT/home-repeat/.agents/AGENTS.md"

# 6. Existing managed-file targets are backed up rather than overwritten (glob avoids second-boundary flakiness).
HOME="$TMP_ROOT/home-backup" mkdir -p "$TMP_ROOT/home-backup/.claude"
printf 'user instructions\n' > "$TMP_ROOT/home-backup/.claude/CLAUDE.md"
HOME="$TMP_ROOT/home-backup" bash "$SYNC_SCRIPT" >/dev/null
[ -L "$TMP_ROOT/home-backup/.claude/CLAUDE.md" ] || fail 'instructions target was not linked'
shopt -s nullglob
backups=("$TMP_ROOT/home-backup/.claude/CLAUDE.md.bak."*)
[ "${#backups[@]}" -eq 1 ] || fail 'existing instructions file was not backed up'
[ "$(cat "${backups[0]}")" = 'user instructions' ] || fail 'backup contents changed'

# 7. Hermes external_dirs awareness skips redundant item-level symlinking when configured.
HOME="$TMP_ROOT/home-hermes" mkdir -p "$TMP_ROOT/home-hermes/.hermes"
printf 'skills:\n  external_dirs:\n    - %s/.agents/skills\n' "$TMP_ROOT/home-hermes" > "$TMP_ROOT/home-hermes/.hermes/config.yaml"
hermes_out="$(PATH="/usr/bin:/bin" HOME="$TMP_ROOT/home-hermes" bash "$SYNC_SCRIPT")"
[[ "$hermes_out" == *"Hermes external_dirs already includes"* ]] || fail "Hermes external_dirs detection failed"

echo 'PASS: sync-agents safety, smart-detection, force, prune, and Hermes tests'
