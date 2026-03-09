defmodule SymphonyElixir.ClaudeParserTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Agent.ClaudeParser

  describe "new/0" do
    test "creates initial parser state" do
      state = ClaudeParser.new()
      assert state.buffer == ""
      assert state.buffer_size == 0
    end
  end

  describe "parse/2 - incremental parsing" do
    test "handles complete single frame" do
      state = ClaudeParser.new()
      frame = "{\"type\": \"message_start\", \"message\": {\"id\": \"msg1\"}}"

      {:ok, events, new_state} = ClaudeParser.parse(state, frame <> "\n")

      assert length(events) == 1
      assert hd(events).type == :message
      assert new_state.buffer == ""
    end

    test "handles partial frame across chunks" do
      state = ClaudeParser.new()
      part1 = "{\"type\": \"message_start\""
      part2 = ", \"message\": {\"id\": \"msg1\"}}"

      {:ok, events1, state1} = ClaudeParser.parse(state, part1)
      assert events1 == []
      assert state1.buffer == part1

      {:ok, events2, state2} = ClaudeParser.parse(state1, part2 <> "\n")
      assert length(events2) == 1
      assert hd(events2).type == :message
      assert state2.buffer == ""
    end

    test "handles concatenated frames in single chunk" do
      state = ClaudeParser.new()

      frames =
        "{\"type\": \"message_start\", \"message\": {\"id\": \"msg1\"}}\n{\"type\": \"content_block_start\", \"content_block\": {\"index\": 0, \"type\": \"text\"}}\n{\"type\": \"content_block_delta\", \"content_block\": {\"index\": 0, \"type\": \"text\"}, \"delta\": {\"type\": \"text_delta\", \"text\": \"Hello\"}}\n{\"type\": \"content_block_stop\", \"content_block\": {\"index\": 0}}\n{\"type\": \"message_stop\"}"

      {:ok, events, _state} = ClaudeParser.parse(state, frames)

      assert length(events) == 5
      assert Enum.map(events, & &1.type) == [:message, :content_block_start, :content_block_delta, :content_block_stop, :done]
    end

    test "handles split frame at boundary" do
      state = ClaudeParser.new()

      # First chunk is incomplete JSON - stays in buffer
      {:ok, events1, state1} = ClaudeParser.parse(state, "{\"type\": \"message_start\"")
      assert events1 == []
      assert state1.buffer =~ "message_start"

      # Second chunk completes the frame
      {:ok, events2, state2} = ClaudeParser.parse(state1, ", \"message\": {\"id\": \"msg1\"}}")
      assert length(events2) == 1
      assert hd(events2).type == :message
      assert state2.buffer == ""

      # Third chunk is incomplete JSON - stays in buffer
      {:ok, events3, state3} = ClaudeParser.parse(state2, "}\n")
      assert events3 == []
      assert state3.buffer == "}"
    end
  end

  describe "parse_frame/1 - malformed frames" do
    test "handles invalid JSON" do
      result = ClaudeParser.parse_frame("{not valid json}")

      assert result.type == :error
      assert result.error.reason != nil
    end

    test "handles empty string" do
      assert is_nil(ClaudeParser.parse_frame(""))
      assert is_nil(ClaudeParser.parse_frame("\n"))
    end

    test "handles unknown event type gracefully" do
      result = ClaudeParser.parse_frame(~s({"type": "unknown_event", "data": "test"}))

      assert result.type == :error
      assert result.error.unknown_type == "unknown_event"
    end

    test "handles partial JSON gracefully" do
      result = ClaudeParser.parse_frame(~s({"type": "message_start"))

      assert result.type == :error
      assert result.error.reason != nil
    end
  end

  describe "to_turn_result/3 - diff bounds" do
    test "no truncation when under limits" do
      events = [
        %{type: :content_block_delta, delta: %{"text" => "Hello world"}, timestamp: DateTime.utc_now()},
        %{type: :done, timestamp: DateTime.utc_now()}
      ]

      result = ClaudeParser.to_turn_result(events, 50_000, 2000)

      assert result.content == "Hello world"
      refute result.content_truncated
    end

    test "truncates by bytes when exceeded" do
      long_text = String.duplicate("a", 60_000)

      events = [
        %{type: :content_block_delta, delta: %{"text" => long_text}, timestamp: DateTime.utc_now()},
        %{type: :done, timestamp: DateTime.utc_now()}
      ]

      result = ClaudeParser.to_turn_result(events, 50_000, 2000)

      assert byte_size(result.content) <= 50_000
      assert result.content_truncated
      assert result.content =~ "[... diff truncated]"
    end

    test "truncates by lines when exceeded" do
      many_lines = Enum.join(1..3000, "\n")

      events = [
        %{type: :content_block_delta, delta: %{"text" => many_lines}, timestamp: DateTime.utc_now()},
        %{type: :done, timestamp: DateTime.utc_now()}
      ]

      result = ClaudeParser.to_turn_result(events, 50_000, 2000)

      line_count = String.split(result.content, "\n") |> length()
      assert line_count <= 2000
      assert result.content_truncated
      assert result.content =~ "[... diff truncated]"
    end

    test "handles both byte and line truncation" do
      # Create content that exceeds both limits
      many_lines = Enum.join(1..3000, "\n") |> String.slice(0, 60_000)

      events = [
        %{type: :content_block_delta, delta: %{"text" => many_lines}, timestamp: DateTime.utc_now()},
        %{type: :done, timestamp: DateTime.utc_now()}
      ]

      result = ClaudeParser.to_turn_result(events, 50_000, 2000)

      line_count = String.split(result.content, "\n") |> length()
      assert line_count <= 2000
      assert byte_size(result.content) <= 50_000
      assert result.content_truncated
    end

    test "accumulates content across multiple deltas with bounds" do
      events = [
        %{type: :content_block_delta, delta: %{"text" => String.duplicate("a", 30_000)}, timestamp: DateTime.utc_now()},
        %{type: :content_block_delta, delta: %{"text" => String.duplicate("b", 30_000)}, timestamp: DateTime.utc_now()},
        %{type: :done, timestamp: DateTime.utc_now()}
      ]

      result = ClaudeParser.to_turn_result(events, 50_000, 2000)

      assert byte_size(result.content) <= 50_000
      assert result.content_truncated
    end
  end

  describe "buffer overflow protection" do
    test "rejects when buffer exceeds max size" do
      state = %{buffer: String.duplicate("x", 999_000), buffer_size: 999_000}
      new_data = String.duplicate("y", 50_000)

      {:error, :buffer_overflow, cleared_state} = ClaudeParser.parse(state, new_data)

      assert cleared_state.buffer == ""
    end
  end
end
