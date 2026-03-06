defmodule SymphonyElixir.Agent.ClaudeBackend do
  @moduledoc """
  Backend adapter for Claude CLI.

  This module implements the `SymphonyElixir.Agent.Backend` behavior and
  communicates with the Claude CLI via Ports using print mode input format.
  """

  require Logger

  alias SymphonyElixir.Agent.SessionIndex
  alias SymphonyElixir.Agent.ClaudeParser

  @behaviour SymphonyElixir.Agent.Backend

  # Local type aliases for the behavior types
  @type session_handle :: SymphonyElixir.Agent.Backend.session_handle()
  @type turn_result :: SymphonyElixir.Agent.Backend.turn_result()

  @impl SymphonyElixir.Agent.Backend
  @spec backend_identifier() :: :claude
  def backend_identifier, do: :claude

  @impl SymphonyElixir.Agent.Backend
  @spec start_session(workspace :: Path.t()) :: {:ok, session_handle()} | {:error, term()}
  def start_session(workspace) when is_binary(workspace) do
    # Run health check first to ensure Claude CLI is available
    case health_check() do
      :ok ->
        start_session_internal(workspace)

      {:error, reason} ->
        Logger.error("ClaudeBackend health check failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp start_session_internal(workspace) do
    # Generate a unique session ID
    session_id = generate_session_id()

    # Build CLI arguments
    cli_args = build_cli_args(workspace)

    # Open a Port to communicate with Claude CLI
    port =
      Port.open({:spawn_executable, claude_executable()}, [
        :binary,
        :use_stdio,
        :stderr_to_stdout,
        :exit_status,
        args: cli_args
      ])

    # Create session handle
    session_handle = %{
      backend: :claude,
      session_id: session_id,
      thread_id: session_id,
      workspace: workspace,
      port: port,
      metadata: %{started_at: DateTime.utc_now()}
    }

    # Register session
    SessionIndex.register(session_handle)

    Logger.info("ClaudeBackend started session: #{inspect(session_id)}")

    {:ok, session_handle}
  rescue
    error ->
      Logger.error("ClaudeBackend failed to start session: #{inspect(error)}")
      {:error, error}
  end

  @impl SymphonyElixir.Agent.Backend
  @spec run_turn(
          session :: session_handle(),
          prompt :: String.t(),
          issue :: map(),
          opts :: keyword()
        ) :: {:ok, turn_result()} | {:error, term()}
  def run_turn(session_handle, prompt, issue, opts \\ [])
      when is_map(session_handle) and is_binary(prompt) and is_map(issue) do
    port = Map.fetch!(session_handle, :port)

    # Build message handler if provided
    message_handler = Keyword.get(opts, :on_message, fn _ -> :ok end)

    # Format prompt with issue info for Claude
    formatted_prompt = format_prompt(prompt, issue)

    # Send the prompt via stdin using print mode
    send_through_port(port, formatted_prompt)

    # Read and parse streaming responses
    result = read_responses(port, message_handler)

    # Handle result
    case result do
      {:ok, events} ->
        turn_result = ClaudeParser.to_turn_result(events)
        {:ok, turn_result}

      {:error, reason} ->
        Logger.error("ClaudeBackend run_turn failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl SymphonyElixir.Agent.Backend
  @spec stop_session(session :: session_handle()) :: :ok
  def stop_session(session_handle) when is_map(session_handle) do
    port = Map.get(session_handle, :port)

    # Send quit command to Claude CLI
    if is_port(port) do
      send_through_port(port, "\q")
      # Give it a moment to clean up
      Process.sleep(100)
      Port.close(port)
    end

    # Unregister session
    SessionIndex.unregister(session_handle)

    Logger.info("ClaudeBackend stopped session: #{inspect(session_handle.session_id)}")
    :ok
  end

  @impl SymphonyElixir.Agent.Backend
  @spec list_sessions() :: [session_handle()]
  def list_sessions do
    SessionIndex.list_sessions(:claude)
  end

  # ============================================================================
  # Health Check
  # ============================================================================

  @spec health_check() :: :ok | {:error, term()}
  def health_check do
    case System.cmd(claude_executable(), ["--version"]) do
      {version_output, 0} ->
        case parse_version(version_output) do
          {:ok, version} ->
            check_version_compatibility(version)

          {:error, reason} ->
            {:error, {:cannot_parse_version, reason, version_output}}
        end

      {error_output, exit_code} ->
        {:error, {:claude_not_available, exit_code, error_output}}
    end
  end

  defp claude_executable do
    SymphonyElixir.Config.claude_command() |> String.split(" ") |> List.first()
  end

  defp parse_version(output) do
    # Expected format: "Claude CLI x.x.x"
    case Regex.run(~r/Claude CLI (\d+)\.(\d+)\.(\d+)/, output) do
      [_, major, minor, patch] ->
        {:ok, {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}}

      _ ->
        {:error, :version_format_unexpected}
    end
  end

  defp check_version_compatibility(version) do
    # Simple version range check - for now just check if >= 1.0.0
    # TODO: Implement proper semver range matching
    case version do
      {major, _, _} when major >= 1 ->
        :ok

      _ ->
        {:error, {:incompatible_version, version}}
    end
  end

  # ============================================================================
  # CLI Arguments
  # ============================================================================

  defp build_cli_args(workspace) do
    args = [
      "--print",
      "--no-ansi"
    ]

    # Add MCP config path if configured
    case SymphonyElixir.Config.claude_mcp_config_path() do
      nil ->
        args

      mcp_path ->
        args ++ ["--mcp-config", mcp_path]
    end
    |> then(fn args ->
      # Add allowed directories if workspace is specified
      if workspace do
        args ++ ["--allowedDirectories", workspace]
      else
        args
      end
    end)
  end

  # ============================================================================
  # Prompt Formatting
  # ============================================================================

  defp format_prompt(prompt, issue) do
    issue_info = """
    Working on Linear issue:
    - Identifier: #{Map.get(issue, :identifier, "unknown")}
    - Title: #{Map.get(issue, :title, "unknown")}

    """

    issue_info <> prompt
  end

  # ============================================================================
  # Port Communication
  # ============================================================================

  defp send_through_port(port, data) do
    # Send data through stdin, appending a newline to trigger processing
    Port.command(port, data <> "\n")
  end

  defp read_responses(port, message_handler) do
    parser_state = ClaudeParser.new()
    read_loop(port, parser_state, message_handler, [])
  end

  defp read_loop(port, parser_state, message_handler, events) do
    receive do
      {^port, {:data, data}} ->
        case ClaudeParser.parse(parser_state, data) do
          {:ok, new_events, new_state} ->
            # Emit events through message handler
            Enum.each(new_events, &message_handler.(&1))

            read_loop(port, new_state, message_handler, events ++ new_events)

          {:error, reason, _new_state} ->
            {:error, {:parse_error, reason}}
        end

      {^port, {:exit_status, 0}} ->
        # Normal exit
        {:ok, events}

      {^port, {:exit_status, code}} ->
        {:error, {:claude_exit, code}}

      {:EXIT, _pid, reason} ->
        {:error, {:port_closed, reason}}
    after
      300_000 ->
        {:error, :timeout}
    end
  end

  # ============================================================================
  # Internal Helpers
  # ============================================================================

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
