# Symphony-claude Elixir

This directory contains the current Elixir/OTP implementation of
Symphony-claude, based on [`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony-claude Elixir is prototype software intended for evaluation in
> trusted environments. It is useful and extensible, but it is still an
> operator-managed internal system rather than a hardened product.

## Screenshot

![Symphony-claude Elixir screenshot](../.github/media/elixir-screenshot.png)

## What This Runtime Does

The Elixir runtime is a supervised orchestration service that:

1. polls Linear for candidate work,
2. creates an isolated workspace per issue,
3. launches the configured agent backend inside that workspace,
4. streams execution updates back into orchestrator state, and
5. exposes terminal and web observability for operators.

When using the Codex app-server backend, Symphony also injects a
`linear_graphql` dynamic tool so repo-local skills can make raw Linear GraphQL
calls during agent execution.

If a claimed issue moves to a terminal state such as `Done`, `Closed`,
`Cancelled`, or `Duplicate`, Symphony stops the active run and cleans up the
matching workspace.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang
versions.

```bash
mise install
mise exec -- elixir --version
```

You also need:

- a Linear personal API key,
- a backend CLI installed on the host,
- a writable workspace root for issue workspaces, and
- a repo-specific `WORKFLOW.md` describing how to bootstrap and run work.

## Quick Start

```bash
git clone https://github.com/synergy0422/Symphony-claude.git
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

If you omit the workflow path, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root <path>`: write runtime logs under a different root
- `--port <port>`: also start the Phoenix observability UI and JSON API

## How To Use It In Your Own Repo

1. Make sure your codebase is already set up for agent-driven work. See
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Create a Linear API key via Linear Settings -> Security & access ->
   Personal API keys.
3. Copy this directory's `WORKFLOW.md` to your target repository.
4. Optionally copy the repo-local skills you want to reuse such as `commit`,
   `push`, `pull`, `land`, and `linear`.
5. Adjust the workflow file for your repo, project slug, workspace root, and
   backend command.
6. Start Symphony against a sandbox or low-risk project first.

## Workflow Configuration

`WORKFLOW.md` uses YAML front matter for typed runtime configuration and a
Markdown body for the issue prompt template.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "your-linear-project"
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  backend: claude
  max_concurrent_agents: 10
  max_turns: 20
claude:
  command: claude
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }}
Body: {{ issue.description }}
```

Notes:

- Missing values fall back to defaults.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when the value is
  `$LINEAR_API_KEY`.
- Path values expand `~`.
- `workspace.root` resolves `$VAR` before path handling.
- `codex.command` and `claude.command` are executed as shell command strings.
- If the prompt body is blank, Symphony falls back to a default issue prompt.
- If `WORKFLOW.md` is missing or contains invalid YAML, startup and scheduling
  are halted until it is fixed.

## Backend Configuration

This runtime exposes backend-related workflow settings and routes execution
through the selected backend.

### Codex Backend

The Codex backend uses OpenAI's
[App Server mode](https://developers.openai.com/codex/app-server/) over stdio.
It is the most feature-complete path for dynamic tool support in this repo.

Example:

```yaml
agent:
  backend: codex
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
  approval_policy: never
```

Codex-specific notes:

- Symphony validates approval, thread sandbox, and turn sandbox settings.
- The default safer policy is used when explicit policy fields are omitted.
- The `linear_graphql` dynamic tool is only available through the Codex
  app-server path in this repo.

### Claude Backend

The Claude backend launches the Claude CLI in non-interactive `--print` mode
and restricts it to the current issue workspace via `--allowedDirectories`.

Example:

```yaml
agent:
  backend: claude
  max_concurrent_agents: 10
  max_turns: 20
claude:
  command: claude
  version_range: ">= 1.0.0"
  turn_timeout_ms: 180000
  read_timeout_ms: 300000
```

Claude-specific notes:

- `claude.command` must support `--version`, `--print`, `--no-ansi`,
  `--allowedDirectories`, and optional `--mcp-config`.
- Symphony validates the configured Claude version range at startup.
- If no explicit Claude MCP config path is supplied, Symphony can generate a
  temporary MCP config file for the session.
- Compatibility details are tracked in
  [docs/claude_cli_compat.md](docs/claude_cli_compat.md).

## Web Dashboard

When `server.port` or the CLI `--port` flag is set, Symphony starts a minimal
Phoenix-based observability service with:

- LiveView dashboard at `/`
- JSON API at `/api/v1/state`
- Per-issue JSON details at `/api/v1/<issue_identifier>`
- Manual refresh endpoint at `/api/v1/refresh`

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `docs/`: supporting runtime notes
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

## Practical Limitations

This implementation is useful today, but keep these constraints in mind:

- it assumes a trusted host environment,
- it depends on backend CLI compatibility on that host,
- it expects repo bootstrap to be encoded in hooks and prompt policy, and
- it is not a hosted control plane or multi-tenant system.

## FAQ

### Why Elixir?

Elixir runs on BEAM/OTP, which is well-suited for supervising long-lived,
failure-prone processes. That maps naturally to issue polling, per-issue
workers, retries, and observability services.

### What's the easiest way to set this up for my own codebase?

Launch an agent in your target repo, point it at this repository, and ask it to
adapt `WORKFLOW.md`, the workspace hooks, and the backend command for your
environment.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
