defmodule SymphonyElixir.Agent.ClaudeBackend do
  @moduledoc """
  Backend adapter for Claude CLI.

  This module implements the `SymphonyElixir.Agent.Backend` behavior and
  communicates with the Claude CLI via Ports using print mode input format.
  """

  require Logger

  alias SymphonyElixir.Agent.ClaudeParser
  alias SymphonyElixir.Agent.SessionIndex

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

  # ============================================================================
  # MCP Config Validation and Generation
  # ============================================================================

  @doc """
  Validates the MCP config path if provided.

  Returns :ok if path is nil (no config) or if the file is readable.
  Returns {:error, reason} if the file exists but is not readable.
  """
  @spec validate_mcp_config_path(String.t() | nil) :: :ok | {:error, term()}
  def validate_mcp_config_path(nil), do: :ok

  def validate_mcp_config_path(path) when is_binary(path) do
    case File.read(path) do
      {:ok, _content} ->
        :ok

      {:error, reason} ->
        {:error, {:mcp_config_unreadable, path, reason}}
    end
  end

  @doc """
  Generates an MCP config file if no explicit path is provided.

  Returns {:ok, generated_path} if a file was generated, or :noop if generation is not needed.
  """
  @spec generate_mcp_config(String.t() | nil) :: {:ok, String.t()} | :noop | {:error, term()}
  def generate_mcp_config(nil) do
    # Generate a temporary MCP config file
    # This would typically include Linear MCP server config based on environment
    generate_mcp_config_file()
  end

  def generate_mcp_config(_explicit_path), do: :noop

  defp generate_mcp_config_file do
    # Create temp directory for MCP config
    tmp_dir = Path.join(System.get_env("TMPDIR", "/tmp"), "symphony_mcp")

    case File.mkdir_p(tmp_dir) do
      :ok ->
        # Generate unique config file path
        session_id = generate_session_id()
        config_path = Path.join(tmp_dir, "mcp_config_#{session_id}.json")

        # Basic MCP config structure (can be extended with Linear MCP settings)
        mcp_config = %{
          "mcpServers" => %{}
        }

        write_mcp_config(config_path, mcp_config)

      {:error, reason} ->
        {:error, {:mcp_tmp_dir_failed, tmp_dir, reason}}
    end
  end

  defp write_mcp_config(config_path, mcp_config) do
    case Jason.encode_to_iodata(mcp_config) do
      {:ok, json} ->
        persist_mcp_config(config_path, json)

      {:error, reason} ->
        {:error, {:mcp_config_encode_failed, reason}}
    end
  end

  defp persist_mcp_config(config_path, json) do
    case File.write(config_path, json) do
      :ok ->
        Logger.debug("Generated MCP config at: #{config_path}")
        {:ok, config_path}

      {:error, reason} ->
        {:error, {:mcp_config_write_failed, config_path, reason}}
    end
  end

  @doc """
  Cleans up generated MCP config file if it was generated (not user-provided).

  Returns :ok always, as the file may or may not exist.
  """
  @spec cleanup_mcp_config(String.t() | nil, boolean()) :: :ok
  def cleanup_mcp_config(_path, false), do: :ok

  def cleanup_mcp_config(nil, _generated), do: :ok

  def cleanup_mcp_config(path, true) do
    case File.rm(path) do
      :ok ->
        Logger.debug("Cleaned up generated MCP config: #{path}")
        :ok

      {:error, :enoent} ->
        # File doesn't exist, that's fine
        :ok

      {:error, reason} ->
        Logger.warning("Failed to cleanup MCP config #{path}: #{inspect(reason)}")
        :ok
    end
  end

  defp start_session_internal(workspace) do
    # Get MCP config path from config
    explicit_mcp_config_path = SymphonyElixir.Config.claude_mcp_config_path()

    # Validate explicit MCP config path if provided
    case validate_mcp_config_path(explicit_mcp_config_path) do
      :ok ->
        case generate_mcp_config(explicit_mcp_config_path) do
          {:ok, generated_path} ->
            do_start_session(workspace, generated_path, true)

          :noop ->
            do_start_session(workspace, explicit_mcp_config_path, false)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_start_session(workspace, mcp_config_path, mcp_config_generated) do
    # Generate a unique session ID
    session_id = generate_session_id()

    # Build CLI arguments
    cli_args = build_cli_args(workspace, mcp_config_path)

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
      metadata: %{
        started_at: DateTime.utc_now(),
        mcp_config_path: mcp_config_path,
        mcp_config_generated: mcp_config_generated
      }
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

    # Clean up generated MCP config file if applicable
    metadata = Map.get(session_handle, :metadata, %{})
    mcp_config_path = Map.get(metadata, :mcp_config_path)
    mcp_config_generated = Map.get(metadata, :mcp_config_generated, false)
    cleanup_mcp_config(mcp_config_path, mcp_config_generated)

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
    case Regex.run(~r/(?:^|[^\d])(\d+\.\d+\.\d+)(?:[^\d]|$)/, output, capture: :all_but_first) do
      [version] ->
        case Version.parse(version) do
          {:ok, parsed_version} -> {:ok, parsed_version}
          :error -> {:error, :invalid_semver}
        end

      _ ->
        {:error, :version_format_unexpected}
    end
  end

  defp check_version_compatibility(%Version{} = version) do
    version_range = SymphonyElixir.Config.claude_version_range()

    case Version.parse_requirement(version_range) do
      {:ok, requirement} ->
        if Version.match?(version, requirement) do
          :ok
        else
          {:error, {:incompatible_version, to_string(version), version_range}}
        end

      :error ->
        {:error, {:invalid_version_range, version_range}}
    end
  end

  # ============================================================================
  # CLI Arguments
  # ============================================================================

  defp build_cli_args(workspace, mcp_config_path) do
    args = [
      "--print",
      "--no-ansi"
    ]

    # Add MCP config path if provided (either explicit or generated)
    case mcp_config_path do
      nil ->
        args

      mcp_path ->
        args ++ ["--mcp-config", mcp_path]
    end
    |> then(fn args ->
      args ++ ["--allowedDirectories", workspace]
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
