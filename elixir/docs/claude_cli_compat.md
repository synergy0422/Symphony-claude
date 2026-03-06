# Claude CLI Compatibility Guide

This document covers the compatibility requirements for using the Claude backend with Symphony.

## Supported Versions

| Claude CLI Version | Symphony Support | Notes |
|-------------------|------------------|-------|
| 1.0.x | Required minimum | First version with `--print` mode |
| 1.1.x | Supported | Full stream-json support |
| 1.2.x | Supported | Current recommended version |

**Minimum required version**: 1.0.0

## Version Validation

Symphony performs a health check on startup that validates the Claude CLI version. If the installed version is not compatible, Symphony will fail fast with a clear error message.

### Manual Version Check

To verify your Claude CLI version:

```bash
claude --version
```

## Validated Flags

The following flags are validated and tested with Symphony:

### Required Flags

- `--print` - Enables structured JSON output for parsing (required for Symphony integration)
- `--model <model>` - Specifies the model to use (e.g., `claude-sonnet-4-20250514`)

### Supported Flags

| Flag | Description | Example |
|------|-------------|---------|
| `--print` | Enable print mode for JSON output | `--print` |
| `--model` | Set the model | `--model claude-sonnet-4-20250514` |
| `--no-auto-tokens` | Disable automatic token counting | `--no-auto-tokens` |
| `--max-turns` | Limit maximum turns | `--max-turns 20` |
| `--allowed-tools` | Restrict available tools | `--allowed-tools Read,Write,Bash` |
| `--dangerously-skip-permissions` | Skip permission prompts | (not recommended) |

### Unsupported Flags

The following flags may cause issues with Symphony and are not recommended:

- Interactive mode flags (conflicts with `--print`)
- `--resume` flags that expect interactive prompts
- Flags that require TTY/terminal interaction

## MCP Server Configuration

### Linear MCP (Required for Linear Operations)

To enable Linear operations with the Claude backend, configure the Linear MCP server:

#### Option 1: Via MCP Config File

Create a JSON config file (e.g., `mcp-linear.json`):

```json
{
  "mcpServers": {
    "linear": {
      "command": "npx",
      "args": ["-y", "@anthropic/mcp-server-linear"]
    }
  }
}
```

Reference it in `WORKFLOW.md`:

```yaml
claude:
  command: claude
  mcp_config_path: /path/to/mcp-linear.json
```

#### Option 2: Via Environment

Ensure the Linear MCP is available in the Claude CLI's tool set:

```bash
export LINEAR_API_KEY=your_linear_api_key
```

### Failure Modes

#### Linear MCP Not Configured

If Linear MCP is not configured:
- The Claude backend will start successfully
- Linear operations will fail with "MCP server not available" errors
- The agent must handle this gracefully or report the limitation

#### Version Incompatibility

If the Claude CLI version is too old:
- Symphony will fail at startup with error: `Claude CLI version X.X.X is not supported. Minimum required: 1.0.0`
- Upgrade Claude CLI to continue

#### Missing --print Support

If the Claude CLI doesn't support `--print` mode:
- Symphony will fail with: `Claude CLI does not support --print mode. Please upgrade to 1.0.0 or higher`

## Timeouts

Configure timeouts in `WORKFLOW.md`:

```yaml
claude:
  command: claude
  turn_timeout_ms: 180000    # 3 minutes per turn (default: 300000)
  read_timeout_ms: 300000    # 5 minutes for reading response (default: 300000)
```

Default values match Codex timeouts for consistency.

## Diff Truncation

The Claude backend includes bounded diff handling to prevent token limit issues:

- `max_bytes`: 50000 bytes per diff
- `max_lines`: 2000 lines per diff
- Truncation strategy: Deterministic with marker indicating truncation

This mirrors Codex behavior for consistency.

## Troubleshooting

### Issue: "claude: command not found"

**Solution**: Ensure Claude CLI is installed and available in PATH:
```bash
which claude
```

### Issue: "Invalid --print flag"

**Solution**: Upgrade Claude CLI to version 1.0.0 or higher:
```bash
claude update
```

### Issue: Linear operations fail with MCP error

**Solution**:
1. Verify Linear MCP is configured in the MCP config file
2. Ensure `LINEAR_API_KEY` environment variable is set
3. Check that `npx` can execute `@anthropic/mcp-server-linear`

### Issue: Session hangs or times out

**Solution**:
1. Increase `turn_timeout_ms` in configuration
2. Check network connectivity
3. Verify the workspace is properly initialized
