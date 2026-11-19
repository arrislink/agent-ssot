---
name: systematic-debugging
description: Use when diagnosing bugs, test failures, build errors, or unexpected runtime behavior before proposing or applying any code changes.
---

# Systematic Root-Cause Debugging

## Core Rule
Never apply speculative or "shotgun" fixes. Identify and verify the root cause before editing code.

## Workflow
1. **Reproduce & Isolate:** Confirm the exact failing command, stack trace, or reproduction steps.
2. **Trace Execution Path:** Use code-graph tools or targeted searches (`rg`, `ast-grep`) to inspect the failing symbol, inputs, and state transitions.
3. **Form a Single Hypothesis:** State clearly what is broken and why, supported by concrete evidence from logs or code.
4. **Minimal Fix:** Change only what is necessary to resolve the root cause without unrelated refactoring.
5. **Verify:** Re-run the original reproduction command and relevant regression checks to confirm resolution.
