defmodule SymphonyElixir.Agent.StreamParser do
  @moduledoc """
  Incremental JSON parser for streaming data.

  Handles partial frames, concatenated frames, and malformed input.
  """

  require Logger

  @max_buffer_size 1_000_000

  @type state :: %{
          buffer: binary(),
          frames: [map()],
          error_count: non_neg_integer()
        }

  @type parse_result :: {:ok, [map()], state()} | {:error, String.t(), state()}

  @spec new() :: state()
  def new, do: %{buffer: "", frames: [], error_count: 0}

  @spec new(binary()) :: state()
  def new(buffer) when is_binary(buffer), do: %{buffer: buffer, frames: [], error_count: 0}

  @spec parse(binary(), state()) :: parse_result()
  def parse(new_data, state) when is_binary(new_data) do
    buffer = state.buffer <> new_data

    if byte_size(buffer) > @max_buffer_size do
      {:error, "buffer overflow: #{byte_size(buffer)} bytes exceeds max #{@max_buffer_size}", %{state | buffer: "", error_count: state.error_count + 1}}
    else
      process_buffer(buffer, %{state | buffer: ""})
    end
  end

  @spec parse_partial(binary(), state()) :: {:partial, state()} | {:error, String.t(), state()}
  def parse_partial(new_data, state) when is_binary(new_data) do
    buffer = state.buffer <> new_data

    if byte_size(buffer) > @max_buffer_size do
      {:error, "buffer overflow", %{state | buffer: "", error_count: state.error_count + 1}}
    else
      # Try to extract complete frames, leave rest in buffer
      case extract_frames(buffer) do
        {:ok, frames, rest} ->
          {:partial, %{state | buffer: rest, frames: state.frames ++ frames}}

        {:incomplete, rest} ->
          {:partial, %{state | buffer: rest}}
      end
    end
  end

  @spec flush(state()) :: {[map()], state()}
  def flush(state) do
    # Try to parse any remaining data in buffer as final frame
    case parse(state.buffer, %{state | buffer: ""}) do
      {:ok, frames, new_state} ->
        {state.frames ++ frames, %{new_state | frames: []}}

      {:error, _reason, new_state} ->
        # Return what's already extracted, discard unparseable buffer
        {state.frames, %{new_state | frames: [], buffer: ""}}
    end
  end

  @spec get_frames(state()) :: [map()]
  def get_frames(state), do: state.frames

  @spec clear_frames(state()) :: state()
  def clear_frames(state), do: %{state | frames: []}

  @spec error_count(state()) :: non_neg_integer()
  def error_count(state), do: state.error_count

  # Private functions

  defp process_buffer(buffer, state) do
    case extract_frames(buffer) do
      {:ok, frames, ""} ->
        {:ok, state.frames ++ frames, %{state | frames: []}}

      {:ok, frames, rest} ->
        {:ok, state.frames ++ frames, %{state | buffer: rest}}

      {:incomplete, rest} ->
        {:ok, state.frames, %{state | buffer: rest}}
    end
  end

  defp extract_frames(buffer) do
    extract_frames(buffer, [])
  end

  defp extract_frames("", acc), do: {:ok, Enum.reverse(acc), ""}

  defp extract_frames(buffer, acc) do
    case Jason.decode(buffer) do
      {:ok, frame} when is_map(frame) ->
        {:ok, [frame | acc], ""}

      {:ok, _} ->
        {:ok, [buffer | acc], ""}

      {:error, _decode_error} ->
        extract_undecodable_frames(buffer, acc)
    end
  end

  defp extract_undecodable_frames(buffer, acc) do
    case parse_ndjson(buffer) do
      {:ok, frames, rest} when frames != [] ->
        {:ok, frames ++ acc, rest}

      _ ->
        extract_incomplete_or_bounded_frames(buffer, acc)
    end
  end

  defp extract_incomplete_or_bounded_frames(buffer, acc) do
    if incomplete_json?(buffer) do
      {:incomplete, buffer}
    else
      extract_frames_at_boundary(buffer, acc)
    end
  end

  defp extract_frames_at_boundary(buffer, acc) do
    case find_json_boundary(buffer) do
      {:found, boundary} when boundary > 0 ->
        decode_frame_prefix(buffer, acc, boundary)

      _ ->
        {:incomplete, buffer}
    end
  end

  defp decode_frame_prefix(buffer, acc, boundary) do
    {prefix, rest} = String.split_at(buffer, boundary)

    case Jason.decode(prefix) do
      {:ok, frame} -> extract_frames(rest, [frame | acc])
      {:error, _} -> {:incomplete, buffer}
    end
  end

  defp parse_ndjson(buffer) do
    lines = String.split(buffer, "\n", trim: true)

    {frames, _remainder} =
      Enum.reduce(lines, {[], ""}, fn line, {frames, _rem} = acc ->
        case Jason.decode(line) do
          {:ok, frame} when is_map(frame) -> {[frame | frames], ""}
          _ -> acc
        end
      end)

    # Find what wasn't parsed
    all_lines = String.split(buffer, "\n")
    processed_count = length(lines)
    remaining_lines = Enum.drop(all_lines, processed_count)
    rest = Enum.join(remaining_lines, "\n")

    if frames != [] do
      {:ok, Enum.reverse(frames), rest}
    else
      {:incomplete, buffer}
    end
  end

  defp incomplete_json?(buffer) do
    trimmed = String.trim(buffer)

    String.ends_with?(trimmed, ":") or
      String.ends_with?(trimmed, ",") or
      String.ends_with?(trimmed, "{") or
      String.ends_with?(trimmed, "[") or
      byte_size(buffer) < 2
  end

  defp find_json_boundary(buffer) do
    # Try to find position where valid JSON starts
    case String.split(buffer, ["{", "["], parts: 2) do
      [_first, rest] when rest != "" ->
        # Found a potential boundary
        prefix_len = byte_size(buffer) - byte_size(rest)
        {:found, prefix_len}

      _ ->
        :not_found
    end
  end
end
