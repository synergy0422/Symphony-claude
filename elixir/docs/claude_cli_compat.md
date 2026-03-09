# Claude CLI Compatibility Notes

This document records the compatibility target for Symphony-claude's Claude
backend.

In this repository, the Claude backend is wired as an execution path through
`agent.backend: claude`, but it still depends on the local Claude CLI matching
the expected non-interactive interface.

## Expected CLI Surface

Symphony-claude expects the configured `claude.command` to support:

- `--version`
- `--print`
- `--no-ansi`
- `--allowedDirectories <path>`
- `--mcp-config <path>` when an MCP config is provided

## Current Runtime Expectations

The current backend validates or assumes:

- Claude CLI version `1.0.0+` by default
- print-mode execution without TTY prompts
- no ANSI control sequences in backend output
- the ability to scope execution to the issue workspace
- bounded diff handling through Symphony-side parsing limits

## Operator Guidance

Before running Symphony-claude with `agent.backend: claude`:

1. Verify `claude --version` succeeds on the target host.
2. Verify the CLI really supports `--print` mode in unattended runs.
3. Confirm the configured command can access any required auth and MCP setup.
4. Test the full `Linear -> Symphony -> Claude` path in a sandbox project
   before using it on higher-signal work.

## Example Workflow Snippet

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
