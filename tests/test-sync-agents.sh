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

# 0. CLI options: --help succeeds and documents --check; unknown option returns non-zero.
help_out="$(bash "$SYNC_SCRIPT" --help)"
[[ "$help_out" == *"--check"* ]] || fail "--help output did not mention --check"
if bash "$SYNC_SCRIPT" --unknown-flag >/dev/null 2>&1; then
  fail "unknown flag should exit non-zero"
fi

# 1. Dry-run with --all from an empty HOME enumerates all source skills and integration targets.
HOME="$TMP_ROOT/dry-home" mkdir -p "$TMP_ROOT/dry-home"
dry_output="$(HOME="$TMP_ROOT/dry-home" bash "$SYNC_SCRIPT" --dry-run --all)"
for skill_path in "$REPO_ROOT"/skills/*; do
  [ -d "$skill_path" ] || continue
  skill="${skill_path##*/}"
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

# 4. Non-project links in downstream targets are preserved by default, while --prune cleans broken links;
#    regular files and dangling links inside ~/.agents/skills are NOT propagated downstream, while space-named skill dirs ARE synced.
HOME="$TMP_ROOT/home-entries" mkdir -p "$TMP_ROOT/home-entries/.claude/skills"
mkdir -p "$TMP_ROOT/home-entries/.agents/skills/my spaced skill"
printf '# Spaced Skill\n' > "$TMP_ROOT/home-entries/.agents/skills/my spaced skill/SKILL.md"
printf 'not a skill dir\n' > "$TMP_ROOT/home-entries/.agents/skills/plain-file.txt"
ln -s "$TMP_ROOT/nonexistent-ssot-skill" "$TMP_ROOT/home-entries/.agents/skills/dangling-ssot"
ln -s "$private_target/private-only" "$TMP_ROOT/home-entries/.claude/skills/private"
ln -s "$TMP_ROOT/nonexistent-target" "$TMP_ROOT/home-entries/.claude/skills/dangling"
printf 'native skill\n' > "$TMP_ROOT/home-entries/.claude/skills/native"
HOME="$TMP_ROOT/home-entries" bash "$SYNC_SCRIPT" >/dev/null
assert_link_to "$TMP_ROOT/home-entries/.claude/skills/private" "$private_target/private-only"
assert_link_to "$TMP_ROOT/home-entries/.claude/skills/dangling" "$TMP_ROOT/nonexistent-target"
assert_link_to "$TMP_ROOT/home-entries/.claude/skills/my spaced skill" "$TMP_ROOT/home-entries/.agents/skills/my spaced skill"
if [ -e "$TMP_ROOT/home-entries/.claude/skills/plain-file.txt" ] || [ -L "$TMP_ROOT/home-entries/.claude/skills/plain-file.txt" ]; then
  fail "regular file in ~/.agents/skills should not propagate downstream"
fi
if [ -e "$TMP_ROOT/home-entries/.claude/skills/dangling-ssot" ] || [ -L "$TMP_ROOT/home-entries/.claude/skills/dangling-ssot" ]; then
  fail "dangling symlink in ~/.agents/skills should not propagate downstream"
fi
[ "$(cat "$TMP_ROOT/home-entries/.claude/skills/native")" = 'native skill' ] || fail 'native skill changed'
HOME="$TMP_ROOT/home-entries" bash "$SYNC_SCRIPT" --prune >/dev/null
[ ! -L "$TMP_ROOT/home-entries/.claude/skills/dangling" ] || fail '--prune did not remove downstream broken symlink'
[ ! -L "$TMP_ROOT/home-entries/.agents/skills/dangling-ssot" ] || fail '--prune did not remove SSOT broken symlink'
assert_link_to "$TMP_ROOT/home-entries/.claude/skills/private" "$private_target/private-only"

# 5. Repeated runs are safe; --force repoints moved symlinks and logs previous target.
HOME="$TMP_ROOT/home-repeat" mkdir -p "$TMP_ROOT/home-repeat/.claude"
HOME="$TMP_ROOT/home-repeat" bash "$SYNC_SCRIPT" >/dev/null
HOME="$TMP_ROOT/home-repeat" bash "$SYNC_SCRIPT" >/dev/null
for skill_path in "$REPO_ROOT"/skills/*; do
  [ -d "$skill_path" ] || continue
  skill="${skill_path##*/}"
  assert_link_to "$TMP_ROOT/home-repeat/.claude/skills/$skill" "$TMP_ROOT/home-repeat/.agents/skills/$skill"
done
ln -sfn "/old/moved/AGENTS.md" "$TMP_ROOT/home-repeat/.claude/CLAUDE.md"
relink_out="$(HOME="$TMP_ROOT/home-repeat" bash "$SYNC_SCRIPT" --force)"
assert_link_to "$TMP_ROOT/home-repeat/.claude/CLAUDE.md" "$TMP_ROOT/home-repeat/.agents/AGENTS.md"
[[ "$relink_out" == *"/old/moved/AGENTS.md -> $TMP_ROOT/home-repeat/.agents/AGENTS.md"* ]] || fail "--force [RELINK] output omitted old target"

# 6. Existing managed-file targets are backed up without collision even within the same second.
stub_bin="$TMP_ROOT/stub-bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/date" <<'EOF'
#!/usr/bin/env bash
echo "20261124120000"
EOF
chmod +x "$stub_bin/date"

HOME="$TMP_ROOT/home-backup" mkdir -p "$TMP_ROOT/home-backup/.claude"
printf 'first instructions\n' > "$TMP_ROOT/home-backup/.claude/CLAUDE.md"
PATH="$stub_bin:/usr/bin:/bin" HOME="$TMP_ROOT/home-backup" bash "$SYNC_SCRIPT" >/dev/null
assert_link_to "$TMP_ROOT/home-backup/.claude/CLAUDE.md" "$TMP_ROOT/home-backup/.agents/AGENTS.md"
rm -f "$TMP_ROOT/home-backup/.claude/CLAUDE.md"
printf 'second instructions\n' > "$TMP_ROOT/home-backup/.claude/CLAUDE.md"
PATH="$stub_bin:/usr/bin:/bin" HOME="$TMP_ROOT/home-backup" bash "$SYNC_SCRIPT" >/dev/null
assert_link_to "$TMP_ROOT/home-backup/.claude/CLAUDE.md" "$TMP_ROOT/home-backup/.agents/AGENTS.md"
[ -f "$TMP_ROOT/home-backup/.claude/CLAUDE.md.bak.20261124120000" ] || fail 'first backup missing'
[ -f "$TMP_ROOT/home-backup/.claude/CLAUDE.md.bak.20261124120000.1" ] || fail 'collision-suffixed second backup missing'
[ "$(cat "$TMP_ROOT/home-backup/.claude/CLAUDE.md.bak.20261124120000")" = 'first instructions' ] || fail 'first backup overwritten'
[ "$(cat "$TMP_ROOT/home-backup/.claude/CLAUDE.md.bak.20261124120000.1")" = 'second instructions' ] || fail 'second backup contents mismatch'

# 7. Hermes external_dirs awareness: recognizes absolute path and ~/.agents/skills, ignores YAML comments.
HOME="$TMP_ROOT/home-hermes" mkdir -p "$TMP_ROOT/home-hermes/.hermes"
printf 'skills:\n  external_dirs:\n    - %s/.agents/skills\n' "$TMP_ROOT/home-hermes" > "$TMP_ROOT/home-hermes/.hermes/config.yaml"
hermes_out="$(PATH="/usr/bin:/bin" HOME="$TMP_ROOT/home-hermes" bash "$SYNC_SCRIPT")"
[[ "$hermes_out" == *"Hermes external_dirs already includes"* ]] || fail "Hermes absolute external_dirs detection failed"
[ ! -e "$TMP_ROOT/home-hermes/.hermes/skills" ] || fail "Hermes skills dir should not be created when external_dirs is active"

HOME="$TMP_ROOT/home-hermes-tilde" mkdir -p "$TMP_ROOT/home-hermes-tilde/.hermes"
printf 'skills:\n  external_dirs: ["~/.agents/skills"]\n' > "$TMP_ROOT/home-hermes-tilde/.hermes/config.yaml"
hermes_tilde_out="$(PATH="/usr/bin:/bin" HOME="$TMP_ROOT/home-hermes-tilde" bash "$SYNC_SCRIPT")"
[[ "$hermes_tilde_out" == *"Hermes external_dirs already includes"* ]] || fail "Hermes tilde external_dirs detection failed"
[ ! -e "$TMP_ROOT/home-hermes-tilde/.hermes/skills" ] || fail "Hermes skills dir should not be created when tilde external_dirs is active"

HOME="$TMP_ROOT/home-hermes-comment" mkdir -p "$TMP_ROOT/home-hermes-comment/.hermes"
printf 'skills:\n  external_dirs:\n    # - ~/.agents/skills\n    # - %s/.agents/skills\n' "$TMP_ROOT/home-hermes-comment" > "$TMP_ROOT/home-hermes-comment/.hermes/config.yaml"
PATH="/usr/bin:/bin" HOME="$TMP_ROOT/home-hermes-comment" bash "$SYNC_SCRIPT" >/dev/null
[ -d "$TMP_ROOT/home-hermes-comment/.hermes/skills" ] || fail "Commented-out Hermes external_dirs falsely suppressed skill syncing"

# 8. --check mode: read-only, fails when unsynced or broken, succeeds when healthy.
HOME="$TMP_ROOT/home-unsynced" mkdir -p "$TMP_ROOT/home-unsynced"
if PATH="/usr/bin:/bin" HOME="$TMP_ROOT/home-unsynced" bash "$SYNC_SCRIPT" --check >/dev/null 2>&1; then
  fail "--check should return non-zero on unsynced HOME"
fi
[ ! -e "$TMP_ROOT/home-unsynced/.agents" ] || fail "--check must not create ~/.agents"

PATH="/usr/bin:/bin" HOME="$TMP_ROOT/smart-home" bash "$SYNC_SCRIPT" --check >/dev/null
ln -s "$TMP_ROOT/missing-skill-target" "$TMP_ROOT/smart-home/.omp/agent/skills/broken-link"
if PATH="/usr/bin:/bin" HOME="$TMP_ROOT/smart-home" bash "$SYNC_SCRIPT" --check >/dev/null 2>&1; then
  fail "--check should return non-zero when broken symlink exists"
fi
rm -f "$TMP_ROOT/smart-home/.omp/agent/skills/broken-link"

# Broken downstream link shadowed by a non-directory file in ~/.agents/skills must still fail --check
printf 'not a skill dir\n' > "$TMP_ROOT/smart-home/.agents/skills/shadowed-non-dir"
ln -s "$TMP_ROOT/missing-skill-target" "$TMP_ROOT/smart-home/.omp/agent/skills/shadowed-non-dir"
if PATH="/usr/bin:/bin" HOME="$TMP_ROOT/smart-home" bash "$SYNC_SCRIPT" --check >/dev/null 2>&1; then
  fail "--check should return non-zero when downstream broken symlink shares name with non-directory SSOT file"
fi
rm -f "$TMP_ROOT/smart-home/.omp/agent/skills/shadowed-non-dir" "$TMP_ROOT/smart-home/.agents/skills/shadowed-non-dir"
PATH="/usr/bin:/bin" HOME="$TMP_ROOT/smart-home" bash "$SYNC_SCRIPT" --check >/dev/null

echo 'PASS: sync-agents safety, smart-detection, force, prune, backup, Hermes, and --check tests'
