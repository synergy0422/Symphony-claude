# Symphony

Symphony is a long-running orchestration service for coding agents. It watches
an issue tracker, creates an isolated workspace for each issue, launches an
agent run inside that workspace, and keeps enough state and observability
around the run to operate it as a real workflow instead of a one-off script.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In the [demo video](.github/media/symphony-demo.mp4), Symphony watches a
Linear board, dispatches work to isolated agent runs, and keeps the workflow
moving through implementation, validation, and handoff._

> [!WARNING]
> Symphony is still an engineering-preview codebase. It is usable in trusted
> environments, but it should be treated as an internal automation system, not
> a hardened multi-tenant platform.

## What Symphony Does

- Polls Linear for issues in configured active states
- Creates one workspace per issue under a controlled workspace root
- Runs an agent backend inside that workspace
- Reconciles active runs when issue state changes
- Retries failed or stalled runs with backoff
- Exposes terminal and web observability for operators
- Keeps runtime policy in-repo via `WORKFLOW.md`

## Current Repository State

This repository contains two things:

1. The language-agnostic [service specification](SPEC.md)
2. A working Elixir/OTP reference implementation under [elixir/](elixir/)

The Elixir runtime is the practical entrypoint today. It includes:

- Linear polling and issue normalization
- Workspace lifecycle hooks
- Agent orchestration and retry logic
- Web and terminal observability
- Backend integration for Codex and Claude-style workflows

## Quick Start

If you want to run the implementation in this repository:

```bash
git clone https://github.com/synergy0422/symphony.git
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
cp WORKFLOW.md WORKFLOW.local.md
$EDITOR WORKFLOW.local.md
LINEAR_API_KEY=... mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  ./WORKFLOW.local.md
```

Start with [elixir/README.md](elixir/README.md) for the full runtime guide and
[docs/INTRODUCTION.md](docs/INTRODUCTION.md) for a higher-level overview of how
to adopt Symphony in your own repo.

## How Symphony Is Structured

- [SPEC.md](SPEC.md): service contract and architecture
- [elixir/README.md](elixir/README.md): runtime setup, configuration, and
  operation
- [elixir/WORKFLOW.md](elixir/WORKFLOW.md): example workflow policy and prompt
  contract
- [docs/INTRODUCTION.md](docs/INTRODUCTION.md): project overview and adoption
  notes
- [elixir/docs/claude_cli_compat.md](elixir/docs/claude_cli_compat.md): Claude
  backend compatibility notes

## Who This Is For

Symphony is a good fit if you already have:

- a repo that is prepared for agent-driven development,
- a Linear-based engineering workflow,
- a need to run unattended issue execution in isolated workspaces, and
- operators who are comfortable owning the runtime and its surrounding
  credentials.

If you want a production-ready hosted control plane, this repository is not
that. If you want an inspectable orchestration layer you can run and extend
yourself, it is much closer to that target.

## Build Your Own

If you prefer to implement Symphony in another language, the main handoff
artifact is the spec:

> Implement Symphony according to [SPEC.md](SPEC.md).

## License

This project is licensed under the [Apache License 2.0](LICENSE).
