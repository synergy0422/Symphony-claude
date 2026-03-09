defmodule SymphonyElixir.Agent.ClaudeParser do
  @moduledoc """
  Stream JSON parser for parsing Claude CLI output events.

  Handles incremental parsing of partial frames, concatenated frames, and malformed frames.
  """

  require Logger

  @max_buffer_size 1_000_000
  @truncation_marker "\n\n[... diff truncated]"

  @type event_type ::
          :message
          | :content_block_delta
          | :content_block_start
          | :content_block_stop
          | :error
          | :done
          | :ping

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
    lines = String.split(data, "\n", trim: false)
    {complete_frames, remaining} = extract_complete_frames(lines)
    {:ok, complete_frames, remaining}
  end

  defp extract_complete_frames([]), do: {[], ""}
  defp extract_complete_frames([""]), do: {[], ""}
  defp extract_complete_frames(["\n"]), do: {[], ""}

  defp extract_complete_frames(lines) do
    {complete, remaining} = Enum.reduce(lines, {[], []}, &extract_complete_frame_line/2)

    {complete, Enum.join(remaining, "\n")}
  end

  defp extract_complete_frame_line(line, {complete, remaining}) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        flush_remaining_frame(complete, remaining)

      decoded_json?(trimmed) ->
        {complete ++ remaining ++ [trimmed], []}

      remaining == [] ->
        {complete, [line]}

      true ->
        {complete, remaining ++ [line]}
    end
  end

  defp flush_remaining_frame(complete, []), do: {complete, []}

  defp flush_remaining_frame(complete, remaining) do
    joined = Enum.join(remaining, "\n")

    if decoded_json?(joined) do
      {complete ++ [joined], []}
    else
      {complete, remaining}
    end
  end

  defp decoded_json?(data), do: match?({:ok, _}, Jason.decode(data))

  @spec to_turn_result([parsed_event()]) :: map()
  def to_turn_result(events) do
    to_turn_result(events, 50_000, 2000)
  end

  @spec to_turn_result([parsed_event()], non_neg_integer(), pos_integer()) :: map()
  def to_turn_result(events, max_bytes, max_lines) do
    Enum.reduce(events, %{backend: :claude}, &accumulate_event(&1, &2, max_bytes, max_lines))
  end

  defp accumulate_event(%{type: :error, error: error}, acc, _max_bytes, _max_lines) do
    Map.put(acc, :error, error)
  end

  defp accumulate_event(%{type: :content_block_delta, delta: delta}, acc, max_bytes, max_lines) do
    current_content = Map.get(acc, :content, "")
    new_content = current_content <> Map.get(delta, "text", "")
    bounded_content = bound_content(new_content, max_bytes, max_lines)

    acc
    |> Map.put(:content, bounded_content.content)
    |> Map.put(:content_truncated, bounded_content.truncated)
  end

  defp accumulate_event(%{type: :message_delta, delta: delta, usage: usage}, acc, _max_bytes, _max_lines) do
    acc
    |> Map.put(:stop_reason, Map.get(delta, "stop_reason"))
    |> Map.put(:usage, usage)
  end

  defp accumulate_event(%{type: :done}, acc, _max_bytes, _max_lines) do
    Map.put(acc, :completed, true)
  end

  defp accumulate_event(_event, acc, _max_bytes, _max_lines), do: acc

  defp bound_content(content, max_bytes, max_lines) do
    truncated_bytes? = byte_size(content) > max_bytes
    lines = String.split(content, "\n")
    truncated_lines? = length(lines) > max_lines

    # Truncation marker has "\n\n" which adds 2 lines
    marker_lines = 2

    cond do
      truncated_bytes? and truncated_lines? ->
        truncated =
          content
          |> String.slice(0, max_bytes - byte_size(@truncation_marker))
          |> String.split("\n")
          |> Enum.take(max_lines - marker_lines)
          |> Enum.join("\n")

        %{content: truncated <> @truncation_marker, truncated: true}

      truncated_bytes? ->
        truncated =
          content
          |> String.slice(0, max_bytes - byte_size(@truncation_marker))
          |> String.split("\n")
          |> Enum.take(max_lines - marker_lines)
          |> Enum.join("\n")

        %{content: truncated <> @truncation_marker, truncated: true}

      truncated_lines? ->
        truncated = Enum.take(lines, max_lines - marker_lines) |> Enum.join("\n")
        %{content: truncated <> @truncation_marker, truncated: true}

      true ->
        %{content: content, truncated: false}
    end
  end
end
