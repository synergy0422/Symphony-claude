defmodule SymphonyElixir.Agent.CodexBackend do
  @moduledoc """
  Backend adapter that wraps the existing Codex AppServer implementation.

  This module implements the `SymphonyElixir.Agent.Backend` behavior while
  preserving the existing app-server JSON-RPC semantics.
  """

  require Logger

  alias SymphonyElixir.Agent.SessionIndex
  alias SymphonyElixir.Codex.AppServer

  @behaviour SymphonyElixir.Agent.Backend

  # Local type aliases for the behavior types
  @type session_handle :: SymphonyElixir.Agent.Backend.session_handle()
  @type turn_result :: SymphonyElixir.Agent.Backend.turn_result()

  @impl SymphonyElixir.Agent.Backend
  @spec backend_identifier() :: :codex
  def backend_identifier, do: :codex

  @impl SymphonyElixir.Agent.Backend
  @spec start_session(workspace :: Path.t()) :: {:ok, session_handle()} | {:error, term()}
  def start_session(workspace) when is_binary(workspace) do
    case AppServer.start_session(workspace) do
      {:ok, app_session} ->
        session_handle = to_session_handle(app_session)
        SessionIndex.register(session_handle)
        Logger.info("CodexBackend started session: #{inspect(session_handle.session_id)}")
        {:ok, session_handle}

      {:error, reason} ->
        Logger.error("CodexBackend failed to start session: #{inspect(reason)}")
        {:error, reason}
    end
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
    app_session = to_app_session(session_handle)

    case AppServer.run_turn(app_session, prompt, issue, opts) do
      {:ok, result} ->
        enriched_result = Map.put(result, :backend, :codex)
        {:ok, enriched_result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl SymphonyElixir.Agent.Backend
  @spec stop_session(session :: session_handle()) :: :ok
  def stop_session(session_handle) when is_map(session_handle) do
    app_session = to_app_session(session_handle)
    SessionIndex.unregister(session_handle)
    AppServer.stop_session(app_session)
    Logger.info("CodexBackend stopped session: #{inspect(session_handle.session_id)}")
    :ok
  end

  @impl SymphonyElixir.Agent.Backend
  @spec list_sessions() :: [session_handle()]
  def list_sessions do
    SessionIndex.list_sessions(:codex)
  end

  # ============================================================================
  # Internal Helpers
  # ============================================================================

  defp to_session_handle(app_session) do
    %{
      backend: :codex,
      session_id: app_session.thread_id,
      thread_id: app_session.thread_id,
      workspace: app_session.workspace,
      port: app_session.port,
      metadata: app_session.metadata,
      # Store original session for internal use
      app_session: app_session
    }
  end

  defp to_app_session(session_handle) do
    Map.get(session_handle, :app_session, session_handle)
  end
end
