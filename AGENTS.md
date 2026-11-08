# AGENTS.md

Instructions for AI coding agents working in this repository.

## What This Repository Is

A collection of small, independent system utilities ("Misc tools"), written as standalone Bash scripts driving standard Linux userland tools. There is no shared build system, no shared runtime, and no inter-tool dependencies.

- Repo layout and rules for adding tools: `specs/architecture/repo-layout.md`
- Technology stack decision: `specs/decisions/001-bash-and-linux-utils-stack.md`

## Current Tools

| Tool | Path | Purpose |
|---|---|---|
| `netns-run` | `network/netns-run/` | run a command in an isolated network namespace, forcing its traffic through a specified gateway |

## Conventions

- Each tool is a standalone script in `<category>/<tool-name>/` with its own `README.md` (user-facing language: Russian).
- Bash scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`; required binaries are checked at runtime (`need_cmd`) before privileged actions.
- Tools must not import, source, or call each other; prefer small duplication over a shared library.
- Tools are Linux-only by design.

## Specifications

Detailed system specs live in `specs/`. Before making structural changes, read the relevant spec:

- Start with `specs/INDEX.md` to find the right document for your task.
- `specs/META.md` defines spec formats and update rules.

Update the affected spec after any change that alters documented behavior (see `specs/META.md` → Update Protocol), including:

- Adding or changing a tool → update its domain spec (`specs/domains/<tool>/`) and, if host-system interaction changes, the corresponding contract in `specs/contracts/`.
- Adding a tool → create `specs/domains/<tool-name>/README.md`, update `specs/INDEX.md`, and register the tool in the root `README.md`.
- Decisions that constrain future work (stack, boundaries) and had rejected alternatives → new ADR in `specs/decisions/`.
