# ADR-001: Bash + Linux system utilities as the tool stack

## Status

Accepted

## Context

The repository collects small, single-purpose system utilities. The first tool, `netns-run`, must orchestrate Linux networking primitives (network namespaces, veth pairs, policy routing, iptables NAT, sysctl). The tools are run interactively by a single user on their own machine, are modified rarely, and their value is in calling the right system utilities with the right arguments at the right time.

## Decision

Tools in this repository are written as standalone Bash scripts (`#!/usr/bin/env bash`, `set -euo pipefail`) that drive standard Linux userland utilities directly: `ip` (iproute2), `iptables`, `nslookup`, `sysctl`, invoked through `sudo`. No compiled language, no package manager, no framework, no shared library between tools.

## Consequences

- Zero build step: a tool is copied/cloned and runs; dependencies are checked at runtime (`need_cmd`).
- The runtime contract is the set of installed system utilities and kernel features, not a language toolchain — scripts must check for required binaries and fail with a clear message.
- Bash's weak error handling is mitigated by `set -euo pipefail`, explicit trap-based cleanup, and idempotent teardown (best-effort `2>/dev/null` deletes in cleanup).
- Parsing system tool output (`ip route get`, `nslookup`) with awk/grep is part of the accepted fragility; output format changes in iproute2 are a maintenance risk.
- Tools are Linux-only by design (netns, iptables, sysctl); portability to macOS/BSD is out of scope.

## Alternatives Considered

- **Go/Python rewrite** — better error handling and arg parsing, but adds a toolchain and dependency management for scripts that are ~500 lines and changed rarely; also complicates privileged operations (a compiled binary would need setuid/capabilities where `sudo` from a script suffices).
- **systemd-networkd / NetworkManager integration** — the tools must work on arbitrary machines without assuming a specific network management stack.
- **iproute2 `ip netns exec` with externally managed namespace files (nsenter-based tooling)** — the orchestration of veth + NAT + policy routing is exactly the value the script adds; delegating it would not remove the complexity.
