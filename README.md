# tools

A collection of small utilities for Linux. Each utility is a self-contained bash script in its own directory, with no shared build step and no dependencies between utilities. Every tool has its own README with usage examples.

Instructions for AI agents — [AGENTS.md](AGENTS.md); internal documentation (specs) — [specs/INDEX.md](specs/INDEX.md).

## Catalog

### network

| Tool | Description |
|---|---|
| [netns-run](network/netns-run/) | Run an arbitrary command in an isolated network namespace, forcing all of its traffic through a given gateway (second provider, VPN, dedicated network card) without changing the host routing. The environment is fully cleaned up after completion. See [network/netns-run/README.md](network/netns-run/README.md) for details. |
