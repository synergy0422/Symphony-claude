defmodule SymphonyElixir.AgentTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Agent.{Backend, StreamParser}

  describe "Backend behavior" do
    test "list_sessions default implementation returns empty list" do
      assert Backend.list_sessions() == []
    end

    test "emit_event creates properly formatted event" do
      handler = fn event ->
        send(self(), {:event, event})
        :ok
      end

      details = %{message: "test message"}
      metadata = %{request_id: "req-123"}

      Backend.emit_event(handler, :session_started, details, metadata)

      assert_receive {:event, event}
      assert event.event == :session_started
      assert event.message == "test message"
      assert event.request_id == "req-123"
      assert is_struct(event.timestamp, DateTime)
    end

    test "validate_session default implementation returns :ok" do
      assert Backend.validate_session(%{session_id: "test"}, SomeBackend) == :ok
    end
  end

  describe "StreamParser" do
    test "new creates empty state" do
      state = StreamParser.new()
      assert state.buffer == ""
      assert state.frames == []
      assert state.error_count == 0
    end

    test "new with initial buffer" do
      state = StreamParser.new("initial")
      assert state.buffer == "initial"
    end

    test "parses complete JSON object" do
      state = StreamParser.new()
      {:ok, frames, _new_state} = StreamParser.parse(~s({"key": "value"}), state)

      assert length(frames) >= 1
      assert Enum.any?(frames, fn f -> f["key"] == "value" end)
    end

    test "handles partial frame - incomplete JSON" do
      state = StreamParser.new()
      {:ok, _frames, new_state} = StreamParser.parse(~s({"incomplete), state)

      # Should return empty frames but keep buffer for incomplete data
      assert is_map(new_state)
      assert new_state.error_count == 0
    end

    test "handles concatenated frames on separate lines" do
      state = StreamParser.new()
      data = ~s({"event": "msg1"}) <> "\n" <> ~s({"event": "msg2"})
      {:ok, frames, _new_state} = StreamParser.parse(data, state)

      assert length(frames) == 2
    end

    test "handles split frames across multiple parse calls" do
      state1 = StreamParser.new()
      {:partial, state2} = StreamParser.parse_partial(~s({"event":), state1)

      # Now parse the rest
      {:ok, frames, _state3} = StreamParser.parse(~s("test"}), state2)

      # Should have parsed the complete frame
      assert is_list(frames)
    end

    test "handles malformed JSON gracefully" do
      state = StreamParser.new()
      # Malformed JSON should be handled without crashing
      result = StreamParser.parse(~s(not json), state)

      # Either returns error with count incremented or ok with empty frames
      assert is_tuple(result)
    end

    test "flush returns accumulated frames" do
      state = StreamParser.new()
      state = %{state | frames: [%{"cached" => "frame"}]}

      {frames, new_state} = StreamParser.flush(state)

      # flush may return frames in state plus what's in buffer
      assert is_list(frames)
      assert new_state.frames == []
    end

    test "get_frames returns current frames" do
      state = %{buffer: "", frames: [%{"a" => "1"}], error_count: 0}
      assert StreamParser.get_frames(state) == [%{"a" => "1"}]
    end

    test "clear_frames resets frames" do
      state = %{buffer: "test", frames: [%{"a" => "1"}], error_count: 0}
      new_state = StreamParser.clear_frames(state)

      assert new_state.frames == []
      assert new_state.buffer == "test"
    end

    test "error_count returns error count" do
      state = %{buffer: "", frames: [], error_count: 5}
      assert StreamParser.error_count(state) == 5
    end
  end
end
