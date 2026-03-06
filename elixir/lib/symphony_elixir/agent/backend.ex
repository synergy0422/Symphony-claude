defmodule SymphonyElixir.Agent.Backend do
  @moduledoc """
  Behavior contract for agent backends, enabling pluggable implementations
  (e.g., Codex, Claude) without changing orchestration semantics.
  """

  require Logger

  # ============================================================================
  # Type Definitions
  # ============================================================================

  @type session_handle :: term()
  @type turn_result :: %{required(String.t()) => term()}
  @type backend_event :: atom()
  @type backend_reason :: term()

  @type start_result :: {:ok, session_handle()} | {:error, backend_reason()}

  @type run_result :: {:ok, turn_result()} | {:error, backend_reason()}

  @type event_payload :: %{
          required(:event) => backend_event(),
          required(:timestamp) => DateTime.t(),
          optional(atom()) => term()
        }

  @type message_handler :: (event_payload() -> :ok)

  # ============================================================================
  # Behavior Callbacks
  # ============================================================================

  @doc """
  Starts a new session for the given workspace.
  Returns a session handle on success.
  """
  @callback start_session(workspace :: Path.t()) :: start_result()

  @doc """
  Runs a single turn within an existing session.
  The prompt is sent to the backend and events are emitted via the message handler.
  """
  @callback run_turn(
              session :: session_handle(),
              prompt :: String.t(),
              issue :: map(),
              opts :: keyword()
            ) :: run_result()

  @doc """
  Stops and cleans up the given session.
  """
  @callback stop_session(session :: session_handle()) :: :ok

  @doc """
  Lists all active sessions managed by this backend.
  Returns a list of session handles.
  """
  @callback list_sessions() :: [session_handle()]

  @doc """
  Returns the backend identifier atom.
  """
  @callback backend_identifier() :: atom()

  # ============================================================================
  # Default Implementations
  # ============================================================================

  @doc """
  Default list_sessions returns empty list. Implementations should override.
  """
  @spec list_sessions() :: [session_handle()]
  def list_sessions, do: []

  @doc """
  Helper to emit events through a message handler with standardized format.
  """
  @spec emit_event(message_handler(), backend_event(), map(), map()) :: :ok
  def emit_event(handler, event, details, metadata \\ %{})
      when is_function(handler, 1) and is_atom(event) and is_map(details) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    handler.(message)
  end

  @doc """
  Validates that a session handle is valid for the given backend.
  """
  @spec validate_session(session_handle(), module()) :: :ok
  def validate_session(_session, _impl), do: :ok
end
