# Repository Agent Guide

Use this short guide to make the smallest end-to-end change that satisfies the requested behavior.

## Working loop

- Read the nearest repository instructions and inspect the current tree before editing.
- Implement one independently observable increment, run its focused check, run the existing native gate when one is present, and review the diff.
- Keep the guide and any plan restartable: record the current state, the next action, and concise command results rather than a transcript.

## Authority and safety

- The current request authorizes ordinary reversible repository-local work only. Release, deployment, production, customer, merge, destructive, and external-write actions need their own authority.
- Preserve tenant isolation and authorization. Never expose secrets or credentials. Protect migration integrity and customer or production data boundaries.
- Stop and report a specific blocker when the requested in-scope outcome needs missing context, approval, a secret, destructive action, or external authority.

## Evidence and completion

- Evidence is the command, result, and short observation needed to reproduce the outcome. Do not add raw proof JSONL, logs, traces, or screenshots to plans or the repository unless they are a required deliverable.
- Keep engineering completion separate from release and production state: passing focused and applicable native checks proves local engineering only; release or production claims require their own observed evidence and authority.
