defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in an isolated workspace with a backend (Codex or Claude).

  This module routes through the configured backend and monitors the backend process
  for crashes, treating process DOWN as a backend_crashed error.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  # Backend module lookup
  @backend_modules %{
    :codex => SymphonyElixir.Agent.CodexBackend,
    :claude => SymphonyElixir.Agent.ClaudeBackend
  }

  # ============================================================================
  # Public API
  # ============================================================================

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting agent run for #{issue_context(issue)}")

    case Workspace.create_for_issue(issue) do
      {:ok, workspace} ->
        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue),
               :ok <- run_backend_turns(workspace, issue, update_recipient, opts) do
            :ok
          else
            {:error, reason} ->
              Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
              raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
          end
        after
          Workspace.run_after_run_hook(workspace, issue)
        end

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp run_backend_turns(workspace, issue, update_recipient, opts) do
    max_turns = Keyword.get(opts, :max_turns, Config.agent_max_turns())
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    # Select backend module based on configuration
    backend = Config.agent_backend()
    backend_module = backend_module(backend)

    with {:ok, session_handle} <- backend_module.start_session(workspace) do
      # Try to monitor the backend process if it's a PID (internal process)
      # For external processes (Ports), we rely on the backend to signal errors
      monitor_ref = maybe_monitor_backend(session_handle)

      try do
        do_run_backend_turns(
          backend_module,
          session_handle,
          monitor_ref,
          workspace,
          issue,
          update_recipient,
          opts,
          issue_state_fetcher,
          1,
          max_turns
        )
      after
        # Demonitor on terminal events if we have a monitor reference
        maybe_demonitor(monitor_ref)
        backend_module.stop_session(session_handle)
      end
    else
      {:error, reason} ->
        Logger.error("Failed to start backend session: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_monitor_backend(session_handle) do
    case get_backend_pid(session_handle) do
      nil -> nil
      pid -> Process.monitor(pid)
    end
  end

  defp maybe_demonitor(nil), do: :ok

  defp maybe_demonitor(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
  end

  defp do_run_backend_turns(backend_module, session_handle, monitor_ref, workspace, issue, update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    # Build message handler
    message_handler = build_message_handler(update_recipient, issue)

    # Run the turn with monitoring
    turn_result = backend_module.run_turn(session_handle, prompt, issue, Keyword.put(opts, :on_message, message_handler))

    # Check for DOWN messages after the call
    case turn_result do
      {:ok, _turn_session} ->
        Logger.info("Completed agent run for #{issue_context(issue)} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

        case continue_with_issue?(issue, issue_state_fetcher) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

            do_run_backend_turns(
              backend_module,
              session_handle,
              monitor_ref,
              workspace,
              refreshed_issue,
              update_recipient,
              opts,
              issue_state_fetcher,
              turn_number + 1,
              max_turns
            )

          {:continue, refreshed_issue} ->
            Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")
            :ok

          {:done, _refreshed_issue} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        # Check if backend crashed (process died)
        case check_backend_down(monitor_ref) do
          {:backend_crashed, crash_reason} ->
            Logger.error("Backend crashed for #{issue_context(issue)}: #{inspect(crash_reason)}")
            {:error, {:backend_crashed, crash_reason}}

          :ok ->
            {:error, reason}
        end
    end
  end

  # Check for any pending DOWN messages
  defp check_backend_down(nil) do
    # No monitor reference - cannot check for DOWN messages
    :ok
  end

  defp check_backend_down(monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        {:backend_crashed, reason}
    after
      0 -> :ok
    end
  end

  defp build_message_handler(recipient, issue) do
    fn message ->
      send_update(recipient, issue, message)
    end
  end

  defp send_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_update(_recipient, _issue, _message), do: :ok

  defp backend_module(backend) when is_atom(backend) do
    case Map.fetch(@backend_modules, backend) do
      {:ok, module} -> module
      :error -> raise "Backend module not available: #{inspect(backend)}. Available: #{inspect(Map.keys(@backend_modules))}"
    end
  end

  defp get_backend_pid(session_handle) do
    # The port field contains either:
    # - A PID for internal backend processes
    # - A Port for external backend processes (like Codex CLI)
    # We can only monitor PIDs directly; for Ports, we rely on the
    # backend to signal errors through return values.
    port = Map.fetch!(session_handle, :port)

    if is_pid(port) do
      port
    else
      nil
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous backend turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.linear_active_states()
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
