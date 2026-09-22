defmodule SymphonyElixir.ThreadResumeSessionTest do
  @moduledoc """
  Session-level behaviour of `codex.resume_threads` against a fake app-server.
  """

  use SymphonyElixir.TestSupport

  setup do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-resume-session-#{System.unique_integer([:positive])}")

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "GEN-6")
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "codex.trace")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(test_root) end)

    {:ok, workspace: workspace, workspace_root: workspace_root, codex_binary: codex_binary, trace_file: trace_file}
  end

  test "a resumed session asks for the stored thread and reports itself resumed", context do
    write_fake_codex!(context.codex_binary, context.trace_file, :resume_ok)
    configure!(context)

    assert {:ok, session} = AppServer.start_session(context.workspace, resume_thread_id: "thread-stored")

    on_exit(fn -> AppServer.stop_session(session) end)

    assert session.resumed == true
    assert session.thread_id == "thread-stored"

    resume_params = sent_params(context.trace_file, "thread/resume")

    assert resume_params["threadId"] == "thread-stored"
    assert is_list(resume_params["dynamicTools"])
    refute sent?(context.trace_file, "thread/start")
  end

  test "a session without a stored thread starts a fresh one", context do
    write_fake_codex!(context.codex_binary, context.trace_file, :start_ok)
    configure!(context)

    assert {:ok, session} = AppServer.start_session(context.workspace)

    on_exit(fn -> AppServer.stop_session(session) end)

    assert session.resumed == false
    refute sent?(context.trace_file, "thread/resume")
  end

  test "a failed resume stops instead of quietly cold-starting", context do
    # A fresh thread has none of the prior context, so silently starting one
    # would have the agent redo work it had already finished.
    write_fake_codex!(context.codex_binary, context.trace_file, :resume_rejected)
    configure!(context)

    assert {:error, {:thread_resume_failed, "thread-stored", _reason}} =
             AppServer.start_session(context.workspace, resume_thread_id: "thread-stored")

    refute sent?(context.trace_file, "thread/start")
  end

  defp configure!(context) do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      codex_command: "#{context.codex_binary} app-server",
      codex_approval_policy: "never",
      codex_resume_threads: true
    )
  end

  defp sent?(trace_file, method) do
    trace_file |> sent_messages() |> Enum.any?(&(&1["method"] == method))
  end

  defp sent_params(trace_file, method) do
    trace_file
    |> sent_messages()
    |> Enum.find(%{}, &(&1["method"] == method))
    |> Map.get("params", %{})
  end

  defp sent_messages(trace_file) do
    trace_file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "JSON:"))
    |> Enum.map(&(&1 |> String.trim_leading("JSON:") |> Jason.decode!()))
  end

  defp write_fake_codex!(path, trace_file, thread_outcome) do
    third_message =
      case thread_outcome do
        :resume_ok -> ~S(printf '%s\n' '{"id":4,"result":{"thread":{"id":"thread-stored"}}}')
        :start_ok -> ~S(printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-fresh"}}}')
        :resume_rejected -> ~S(printf '%s\n' '{"id":4,"error":{"code":-32000,"message":"no rollout found"}}')
      end

    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    #!/bin/sh
    trace_file="#{trace_file}"
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"
      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          ;;
        3)
          #{third_message}
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end
end
