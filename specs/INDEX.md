# INDEX

Navigation for the specification system. Format and update rules: [META.md](META.md).

## Task → Spec

| Task | Spec(s) |
|---|---|
| Understand the repository as a whole (what this is, how tools are organized) | [architecture/repo-layout.md](architecture/repo-layout.md) |
| Add a new tool to the collection | [architecture/repo-layout.md](architecture/repo-layout.md) (Adding a New Tool) |
| Understand or change netns-run behavior (routes, excludes, teardown) | [domains/netns-run/README.md](domains/netns-run/README.md) |
| Understand or change netns-run setup/cleanup order, generated IDs | [domains/netns-run/environment-lifecycle.md](domains/netns-run/environment-lifecycle.md) |
| Touch host-system interaction (ip/iptables/sysctl/sudo calls, parsing) | [contracts/netns-run-host-system.md](contracts/netns-run-host-system.md) |
| Change a fundamental stack/boundary decision | [decisions/001-bash-and-linux-utils-stack.md](decisions/001-bash-and-linux-utils-stack.md); record the new decision per [META.md Update Protocol](META.md#update-protocol) |
| Write a new ADR | [decisions/_template.md](decisions/_template.md) |

## Dependency Graph

```
specs/
├── architecture/repo-layout.md   (repository model; guides new tools)
│        │
│        ▼ references
├── domains/netns-run/
│   ├── README.md                 (domain entry point)
│   └── environment-lifecycle.md  (detail; referenced by README)
│        │
│        ▼ implements via
├── contracts/netns-run-host-system.md  (host-system boundary; derived from lifecycle)
│
└── decisions/001-bash-and-linux-utils-stack.md  (stack decision constraining all tools)
```

Domain specs describe intended behavior; the contract documents the boundary to the host system; ADRs constrain cross-tool decisions. There are no cross-domain dependencies between tools (see [architecture/repo-layout.md Invariants](architecture/repo-layout.md#invariants)).

## Directory

```
specs/
├── META.md                                  spec formats and update rules
├── INDEX.md                                 this file
├── architecture/
│   └── repo-layout.md                       repository model: independent tools
├── domains/
│   └── netns-run/
│       ├── README.md                        netns-run domain overview
│       └── environment-lifecycle.md         setup/run/cleanup lifecycle detail
├── contracts/
│   └── netns-run-host-system.md             tool <-> host system contract
└── decisions/
    ├── _template.md                         ADR template
    └── 001-bash-and-linux-utils-stack.md    stack decision (bash + ip/iptables/sysctl)
```
