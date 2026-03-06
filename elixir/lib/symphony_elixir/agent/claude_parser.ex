defmodule SymphonyElixir.Agent.ClaudeParser do
  @moduledoc """
  Stream JSON parser for parsing Claude CLI output events.

  Handles incremental parsing of partial frames, concatenated frames, and malformed frames.
  """

  require Logger

  @max_buffer_size 1_000_000

  @type event_type :: :message | :content_block_delta | :content_block_start | :content_block_stop | :error | :done | :ping

  @type parsed_event :: %{
          required(:type) => event_type(),
          optional(:message) => map(),
          optional(:content_block) => map(),
          optional(:delta) => map(),
          optional(:error) => map(),
          optional(:usage) => map(),
          optional(:timestamp) => DateTime.t()
        }

  @type state :: %{
          buffer: String.t(),
          buffer_size: non_neg_integer()
        }

  @spec new() :: state()
  def new, do: %{buffer: "", buffer_size: 0}

  @spec parse(state(), String.t()) :: {:ok, [parsed_event()], state()} | {:error, term(), state()}
  def parse(%{buffer: buffer} = state, new_data) do
    combined = buffer <> new_data
    new_size = byte_size(combined)

    if new_size > @max_buffer_size do
      {:error, :buffer_overflow, %{state | buffer: ""}}
    else
      {:ok, frames, remaining} = split_frames(combined)
      events = Enum.map(frames, &parse_frame/1) |> Enum.reject(&is_nil/1)
      {:ok, events, %{state | buffer: remaining, buffer_size: byte_size(remaining)}}
    end
  end

  @spec parse_frame(String.t()) :: parsed_event() | nil
  def parse_frame(""), do: nil
  def parse_frame("\n"), do: nil

  def parse_frame(json) do
    case Jason.decode(json) do
      {:ok, %{"type" => type} = data} ->
        build_event(type, data)

      {:error, reason} ->
        Logger.warning("Failed to parse Claude JSON frame: #{inspect(reason)}, data: #{String.slice(json, 0..100)}")

        %{
          type: :error,
          error: %{reason: reason, raw: String.slice(json, 0..500)},
          timestamp: DateTime.utc_now()
        }
    end
  end

  defp build_event("message_start", data) do
    %{
      type: :message,
      message: Map.get(data, "message", %{}),
      timestamp: DateTime.utc_now()
    }
  end

  defp build_event("content_block_start", data) do
    %{
      type: :content_block_start,
      content_block: Map.get(data, "content_block", %{}),
      timestamp: DateTime.utc_now()
    }
  end

  defp build_event("content_block_delta", data) do
    %{
      type: :content_block_delta,
      content_block: Map.get(data, "content_block", %{}),
      delta: Map.get(data, "delta", %{}),
      timestamp: DateTime.utc_now()
    }
  end

  defp build_event("content_block_stop", _data) do
    %{
      type: :content_block_stop,
      timestamp: DateTime.utc_now()
    }
  end

  defp build_event("message_delta", data) do
    %{
      type: :message,
      delta: Map.get(data, "delta", %{}),
      usage: Map.get(data, "usage", %{}),
      timestamp: DateTime.utc_now()
    }
  end

  defp build_event("message_stop", _data) do
    %{
      type: :done,
      timestamp: DateTime.utc_now()
    }
  end

  defp build_event("error", data) do
    %{
      type: :error,
      error: Map.get(data, "error", %{}),
      timestamp: DateTime.utc_now()
    }
  end

  defp build_event("ping", data) do
    %{
      type: :ping,
      data: Map.get(data, "data", %{}),
      timestamp: DateTime.utc_now()
    }
  end

  defp build_event(type, data) do
    Logger.debug("Unknown Claude event type: #{inspect(type)}, data: #{inspect(data)}")

    %{
      type: :error,
      error: %{unknown_type: type, data: data},
      timestamp: DateTime.utc_now()
    }
  end

  defp split_frames(data) do
    frames = String.split(data, "\n", trim: true)
    {:ok, frames, ""}
  end

  @spec to_turn_result([parsed_event()]) :: map()
  def to_turn_result(events) do
    Enum.reduce(events, %{backend: :claude}, &accumulate_event/2)
  end

  defp accumulate_event(%{type: :error, error: error}, acc) do
    Map.put(acc, :error, error)
  end

  defp accumulate_event(%{type: :content_block_delta, delta: delta}, acc) do
    current_content = Map.get(acc, :content, "")
    new_content = current_content <> Map.get(delta, "text", "")
    Map.put(acc, :content, new_content)
  end

  defp accumulate_event(%{type: :message_delta, delta: delta, usage: usage}, acc) do
    acc
    |> Map.put(:stop_reason, Map.get(delta, "stop_reason"))
    |> Map.put(:usage, usage)
  end

  defp accumulate_event(%{type: :done}, acc) do
    Map.put(acc, :completed, true)
  end

  defp accumulate_event(_event, acc), do: acc
end
