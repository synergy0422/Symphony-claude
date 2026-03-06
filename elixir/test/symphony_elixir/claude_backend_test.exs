defmodule SymphonyElixir.ClaudeBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.ClaudeBackend

  test "start_session preserves MCP config generation errors" do
    executable = write_fake_claude!("echo 'Claude CLI 1.2.3' >&1")
    blocking_path = temp_file_path("tmpdir-block")
    File.write!(blocking_path, "not a directory")

    original_tmpdir = System.get_env("TMPDIR")

    try do
      System.put_env("TMPDIR", blocking_path)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "claude",
        claude_command: executable
      )

      assert {:error, {:mcp_tmp_dir_failed, path, reason}} =
               ClaudeBackend.start_session(temp_dir("workspace"))

      assert String.ends_with?(path, "/symphony_mcp")
      assert reason in [:enoent, :enotdir]
    after
      restore_env("TMPDIR", original_tmpdir)
      File.rm(blocking_path)
      File.rm(executable)
    end
  end

  test "stop_session removes generated MCP config from metadata" do
    generated_path = temp_file_path("generated-mcp")
    File.write!(generated_path, "{\"mcpServers\":{}}")

    session_handle = %{
      session_id: "claude-session-stop",
      backend: :claude,
      port: nil,
      metadata: %{
        mcp_config_path: generated_path,
        mcp_config_generated: true
      }
    }

    assert :ok = ClaudeBackend.stop_session(session_handle)
    refute File.exists?(generated_path)
  end

  test "health_check enforces configured version requirement" do
    executable = write_fake_claude!("echo 'Claude CLI 1.2.3 (build abc)' >&1")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "claude",
        claude_command: executable,
        claude_version_range: ">= 2.0.0"
      )

      assert {:error, {:incompatible_version, "1.2.3", ">= 2.0.0"}} =
               ClaudeBackend.health_check()
    after
      File.rm(executable)
    end
  end

  defp write_fake_claude!(body) do
    script_path = temp_file_path("fake-claude")

    File.write!(
      script_path,
      """
      #!/bin/sh
      #{body}
      """
    )

    File.chmod!(script_path, 0o755)
    script_path
  end

  defp temp_file_path(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp temp_dir(prefix) do
    path = temp_file_path(prefix)
    File.mkdir_p!(path)
    path
  end
end
