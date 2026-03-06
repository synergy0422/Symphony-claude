defmodule SymphonyElixir.Agent.SessionIndex do
  @moduledoc """
  ETS-based session index for tracking active backend sessions.

  Provides register/unregister/list APIs for session lifecycle management.
  This enables operators to see active sessions and handle crashes gracefully.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Agent.Backend

  @table_name :symphony_session_index
  @table_options [:named_table, :set, :public, {:read_concurrency, true}, {:write_concurrency, true}]

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the SessionIndex. Called during application startup.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a session with the index.

  The session_handle should be a map containing at least :session_id and :backend keys.
  """
  @spec register(session_handle :: Backend.session_handle()) :: :ok
  def register(session_handle) when is_map(session_handle) do
    session_id = extract_session_id(session_handle)
    backend = extract_backend(session_handle)

    :ets.insert(@table_name, {
      session_id,
      session_handle,
      backend,
      DateTime.utc_now()
    })

    Logger.debug("Session registered: session_id=#{session_id} backend=#{backend}")
    :ok
  end

  @doc """
  Unregisters a session from the index.
  """
  @spec unregister(session_handle :: Backend.session_handle()) :: :ok
  def unregister(session_handle) when is_map(session_handle) do
    session_id = extract_session_id(session_handle)

    :ets.delete(@table_name, session_id)
    Logger.debug("Session unregistered: session_id=#{session_id}")
    :ok
  end

  @doc """
  Unregisters a session by session ID.
  """
  @spec unregister_by_id(session_id :: term()) :: :ok
  def unregister_by_id(session_id) do
    :ets.delete(@table_name, session_id)
    Logger.debug("Session unregistered by ID: session_id=#{inspect(session_id)}")
    :ok
  end

  @doc """
  Lists all active sessions.
  """
  @spec list_sessions() :: [Backend.session_handle()]
  def list_sessions do
    @table_name
    |> :ets.tab2list()
    |> Enum.map(fn {_session_id, session_handle, _backend, _started_at} -> session_handle end)
  end

  @doc """
  Lists all active sessions for a specific backend.
  """
  @spec list_sessions(backend :: atom()) :: [Backend.session_handle()]
  def list_sessions(backend) when is_atom(backend) do
    @table_name
    |> :ets.tab2list()
    |> Enum.filter(fn {_session_id, _handle, b, _started_at} -> b == backend end)
    |> Enum.map(fn {_session_id, session_handle, _backend, _started_at} -> session_handle end)
  end

  @doc """
  Looks up a session by ID.
  """
  @spec lookup(session_id :: term()) :: {:ok, Backend.session_handle()} | :not_found
  def lookup(session_id) do
    case :ets.lookup(@table_name, session_id) do
      [{^session_id, session_handle, _backend, _started_at}] ->
        {:ok, session_handle}

      [] ->
        :not_found
    end
  end

  @doc """
  Returns the count of active sessions.
  """
  @spec session_count() :: non_neg_integer()
  def session_count do
    :ets.info(@table_name, :size)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(_opts) do
    # Create ETS table if it doesn't exist
    case :ets.info(@table_name) do
      :undefined ->
        :ets.new(@table_name, @table_options)
        Logger.info("SessionIndex ETS table created")

      _ ->
        Logger.debug("SessionIndex ETS table already exists")
    end

    {:ok, %{}}
  end

  # ============================================================================
  # Internal Helpers
  # ============================================================================

  defp extract_session_id(session_handle) do
    Map.get(session_handle, :session_id) || Map.get(session_handle, :thread_id)
  end

  defp extract_backend(session_handle) do
    Map.get(session_handle, :backend, :unknown)
  end
end
