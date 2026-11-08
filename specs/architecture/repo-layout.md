# Repository Layout — Collection of Independent Tools

## Context

This repository is a grab-bag of small, self-contained utilities ("Misc tools"). There is no shared runtime, no shared build system, and no inter-tool communication. Each tool lives in its own directory with its own README and its own dependencies. The spec system mirrors this: one tool = one domain under `specs/domains/<tool-name>/`.

## Tool Directory Model

```
tools/ (repo root)
├── README.md              human-facing catalog of tools, grouped by category
├── AGENTS.md              agent instructions + pointer to specs/
├── LICENSE
├── specs/                 specification system (see META.md)
└── <category>/
    └── <tool-name>/       one directory per tool
        ├── README.md      tool documentation (usage, options, examples)
        └── <tool files>   implementation (e.g. netns-run.sh)
```

- `<category>` is a loose thematic grouping (currently `network/`). It has no build or runtime meaning — purely organizational.
- Every tool directory MUST contain a `README.md` documenting usage.

## Adding a New Tool

1. Create `<category>/<tool-name>/` with implementation + `README.md`.
2. Create spec `specs/domains/<tool-name>/README.md` following the Domain README template in [META.md](../META.md).
3. If the tool touches the host system (network, sysctl, filesystem, services), create a contract spec `specs/contracts/<tool-name>-<touchpoint>.md`.
4. Register the tool in the root `README.md` catalog and in [INDEX.md](../INDEX.md).
5. Record any stack/boundary decisions in `decisions/` if they pass the ADR bar (see [META.md Update Protocol](../META.md#update-protocol)).

## Invariants

- Tools are independent: a tool MUST NOT import, source, or call another tool in this repository.
- Every tool is runnable directly from its own directory; there is no shared entry point or build step for the repo as a whole.
- Every tool directory contains a `README.md` in the same language as the tool's user-facing messages (currently Russian).
- Each tool's spec domain directory name matches the tool directory name in the repo.

## Anti-Patterns

- **Shared library of common shell functions** — tempting as tools grow, but it couples independent tools; prefer duplicating a few lines over a cross-tool dependency. If duplication becomes painful, that is a signal the tool deserves its own repo, not a shared core.
- **Tool README as the only documentation** — README documents usage for humans; behavior, invariants and host-system effects belong in `specs/domains/<tool>/` and `specs/contracts/`.
- **Category directories as namespaces** — do not put shared code in `network/` or invent import paths based on categories; a category is a folder, nothing more.
