---
name: verification-before-completion
description: Use before declaring any task, bugfix, refactoring, or configuration change complete to ensure empirical verification has been executed.
---

# Verification Before Completion

## Core Rule
Evidence before assertions. Never claim a change works, builds, or passes tests without running the actual verification command in the current session.

## Checklist
1. **Identify Verification Commands:** Locate the project's test, build, lint, or typecheck commands.
2. **Execute & Inspect Exit Code:** Run the commands with quiet/concise flags and confirm exit status `0`.
3. **Check Diff Hygiene:** Run `git status` and `git diff` to ensure no unintended files, debug logs, or secrets are left behind.
4. **Report Concrete Results:** Summarize what was verified and include key command outcomes in the final response.
