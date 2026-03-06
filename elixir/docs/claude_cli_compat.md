# Claude CLI Compatibility Notes

This document records rollout targets for the upcoming Claude backend. In this branch, Symphony
parses Claude-related workflow settings but still executes only through the Codex runtime path.

## Current Status

- `claude.command`, `claude.turn_timeout_ms`, and `claude.read_timeout_ms` are parsed from `WORKFLOW.md`
- `agent.backend: codex` remains the only supported runtime backend in this branch
- selecting `agent.backend: claude` fails clearly instead of being silently ignored

## Planned Claude Rollout Targets

These are the compatibility targets the eventual Claude backend should satisfy:

- Claude CLI version `1.0.0+`
- support for `--print` mode
- support for non-interactive execution without TTY prompts
- bounded diff handling equivalent to the Codex path (`max_bytes=50000`, `max_lines=2000`)

## Planned Workflow Surface

```yaml
agent:
  backend: claude

claude:
  command: claude
  turn_timeout_ms: 180000
  read_timeout_ms: 300000
```

These keys are intentionally documented now so workflow files can be prepared before the runtime
integration lands.

## Operator Guidance

Until the Claude backend is implemented:

- keep production workflows on `agent.backend: codex`
- treat this document as a rollout checklist, not as proof that Claude execution is active
- verify any future Claude enablement against real tests and runtime checks before updating the main README again
