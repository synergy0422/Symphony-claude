# Symphony Introduction

Symphony is an orchestration layer for coding-agent work. Instead of manually
opening a terminal, copying an issue into a prompt, and supervising every step,
you give Symphony a workflow contract and let it run issue execution as a
managed service.

## Core Model

At a high level, Symphony does four things:

1. Reads candidate work from Linear
2. Creates an isolated workspace for each issue
3. Starts an agent backend inside that workspace
4. Reconciles, retries, and observes the run until the issue leaves active
   states

This makes agent execution operationally tractable:

- each issue gets its own filesystem boundary,
- prompts and workflow policy live in version control,
- retries and cleanup happen in one place, and
- operators have a single state surface to inspect.

## Repository Contents

This repository has both a spec and an implementation.

- `SPEC.md` is the product-agnostic contract for the system.
- `elixir/` is the current Elixir/OTP reference implementation.

If you want to evaluate or extend the system today, start with `elixir/`.

## Practical Capabilities

The current implementation is aimed at trusted internal environments and
supports:

- Linear-backed issue polling
- per-issue isolated workspaces
- configurable workspace lifecycle hooks
- backend-driven issue execution
- retry and stall-recovery logic
- terminal and web observability
- workflow-defined prompts and runtime policy via `WORKFLOW.md`

## Operating Assumptions

Symphony assumes a repo and team workflow that are already agent-friendly:

- the target repository can be cloned and bootstrapped non-interactively,
- the agent CLI and its credentials already exist on the host,
- Linear access is available through a personal API token, and
- your team is comfortable running automation with meaningful repository
  access.

This is not a fully sealed automation appliance. It is an operator-owned
orchestration service.

## Minimal Adoption Path

To adopt Symphony for another repository:

1. Pick the implementation path: use `elixir/` directly or reimplement from
   `SPEC.md`.
2. Create a repo-local `WORKFLOW.md` with:
   - Linear project slug
   - workspace root
   - workspace bootstrap hooks
   - backend command
   - the prompt template used for issue execution
3. Verify the backend CLI works unattended on the host.
4. Run Symphony against a small Linear project or sandbox board first.
5. Add observability and runtime hygiene before expanding scope.

## What Symphony Is Not

Symphony is not:

- a hosted SaaS,
- a multi-tenant job platform,
- a replacement for repo-specific workflow design, or
- a guarantee that your agent workflow is safe by default.

You still own the repo contract, credential model, and operational guardrails.

## Next Documents

- Root overview: [README.md](../README.md)
- Runtime setup: [elixir/README.md](../elixir/README.md)
- Reference workflow contract: [elixir/WORKFLOW.md](../elixir/WORKFLOW.md)
- Specification: [SPEC.md](../SPEC.md)
