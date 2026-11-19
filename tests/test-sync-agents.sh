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

# Dry-run from an empty HOME must enumerate all source skills and integration targets.
HOME="$TMP_ROOT/dry-home" mkdir -p "$TMP_ROOT/dry-home"
dry_output="$(HOME="$TMP_ROOT/dry-home" bash "$SYNC_SCRIPT" --dry-run)"
for skill_path in "$REPO_ROOT"/skills/*; do
  [ -d "$skill_path" ] || continue
  skill="$(basename "$skill_path")"
  [[ "$dry_output" == *"$TMP_ROOT/dry-home/.agents/skills/$skill"* ]] || fail "dry-run omitted primary skill $skill"
  [[ "$dry_output" == *"$TMP_ROOT/dry-home/.claude/skills/$skill"* ]] || fail "dry-run omitted downstream skill $skill"
done

# Existing skill container symlinks are preserved; syncing does not replace directories.
private_target="$TMP_ROOT/private-skills"
mkdir -p "$private_target/private-only"
ln -s "$private_target" "$TMP_ROOT/linked-skills"
HOME="$TMP_ROOT/home-container" mkdir -p "$TMP_ROOT/home-container/.claude"
ln -s "$private_target" "$TMP_ROOT/home-container/.claude/skills"
HOME="$TMP_ROOT/home-container" bash "$SYNC_SCRIPT" >/dev/null
assert_link_to "$TMP_ROOT/home-container/.claude/skills" "$private_target"
[ -d "$private_target/private-only" ] || fail "private skill was lost"

# Non-project links (including dangling links) are preserved, while native files are retained.
HOME="$TMP_ROOT/home-entries" mkdir -p "$TMP_ROOT/home-entries/.claude/skills"
mkdir -p "$TMP_ROOT/home-entries/.agents/skills"
ln -s "$private_target/private-only" "$TMP_ROOT/home-entries/.claude/skills/private"
ln -s "$TMP_ROOT/nonexistent-target" "$TMP_ROOT/home-entries/.claude/skills/dangling"
printf 'native skill\n' > "$TMP_ROOT/home-entries/.claude/skills/native"
HOME="$TMP_ROOT/home-entries" bash "$SYNC_SCRIPT" >/dev/null
assert_link_to "$TMP_ROOT/home-entries/.claude/skills/private" "$private_target/private-only"
assert_link_to "$TMP_ROOT/home-entries/.claude/skills/dangling" "$TMP_ROOT/nonexistent-target"
[ "$(cat "$TMP_ROOT/home-entries/.claude/skills/native")" = 'native skill' ] || fail 'native skill changed'

# Repeated runs are safe; project-managed links refresh to their current source.
HOME="$TMP_ROOT/home-repeat" mkdir -p "$TMP_ROOT/home-repeat"
HOME="$TMP_ROOT/home-repeat" bash "$SYNC_SCRIPT" >/dev/null
HOME="$TMP_ROOT/home-repeat" bash "$SYNC_SCRIPT" >/dev/null
for skill_path in "$REPO_ROOT"/skills/*; do
  [ -d "$skill_path" ] || continue
  skill="$(basename "$skill_path")"
  assert_link_to "$TMP_ROOT/home-repeat/.claude/skills/$skill" "$TMP_ROOT/home-repeat/.agents/skills/$skill"
done

# Existing managed-file targets are backed up rather than overwritten.
HOME="$TMP_ROOT/home-backup" mkdir -p "$TMP_ROOT/home-backup/.claude"
printf 'user instructions\n' > "$TMP_ROOT/home-backup/.claude/CLAUDE.md"
HOME="$TMP_ROOT/home-backup" bash "$SYNC_SCRIPT" >/dev/null
[ -L "$TMP_ROOT/home-backup/.claude/CLAUDE.md" ] || fail 'instructions target was not linked'
backup="$TMP_ROOT/home-backup/.claude/CLAUDE.md.bak.$(date +%Y%m%d%H%M%S)"
[ -f "$backup" ] || fail 'existing instructions file was not backed up'
[ "$(cat "$backup")" = 'user instructions' ] || fail 'backup contents changed'

echo 'PASS: sync-agents safety and dry-run tests'
