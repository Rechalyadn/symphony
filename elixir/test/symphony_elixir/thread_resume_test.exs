defmodule SymphonyElixir.ThreadResumeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ThreadStore

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "symphony-thread-store-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    {:ok, workspace: workspace}
  end

  describe "ThreadStore" do
    test "load returns nil before anything is recorded", %{workspace: workspace} do
      assert ThreadStore.load(workspace) == nil
    end

    test "save then load round-trips the binding", %{workspace: workspace} do
      assert :ok = ThreadStore.save(workspace, "thread-abc", "Executing")

      assert %{thread_id: "thread-abc", last_state: "Executing", last_run_at: last_run_at} =
               ThreadStore.load(workspace)

      assert {:ok, _, _} = DateTime.from_iso8601(last_run_at)
    end

    test "save overwrites the previous binding", %{workspace: workspace} do
      :ok = ThreadStore.save(workspace, "thread-old", "Scoped")
      :ok = ThreadStore.save(workspace, "thread-new", "Executing")

      assert %{thread_id: "thread-new", last_state: "Executing"} = ThreadStore.load(workspace)
    end

    test "a corrupt record reads as a cold start rather than raising", %{workspace: workspace} do
      path = ThreadStore.path(workspace)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{not json")

      assert ThreadStore.load(workspace) == nil
    end

    test "a record without a thread id reads as a cold start", %{workspace: workspace} do
      path = ThreadStore.path(workspace)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(%{"last_state" => "Scoped"}))

      assert ThreadStore.load(workspace) == nil
    end

    test "remote worker hosts are never tracked", %{workspace: workspace} do
      assert :ok = ThreadStore.save(workspace, "thread-abc", "Executing", "worker-1")
      refute File.exists?(ThreadStore.path(workspace))
      assert ThreadStore.load(workspace, "worker-1") == nil
    end

    test "the record lives inside the workspace so cleanup removes it", %{workspace: workspace} do
      :ok = ThreadStore.save(workspace, "thread-abc", "Executing")
      assert String.starts_with?(ThreadStore.path(workspace), workspace)
    end
  end

  describe "resume prompt" do
    setup do
      issue = %Issue{
        id: "issue-1",
        identifier: "GEN-6",
        title: "Measure something",
        state: "Executing",
        description: "body",
        url: "https://linear.app/x/issue/GEN-6"
      }

      {:ok, issue: issue}
    end

    test "names the transition and points at unread comments", %{issue: issue} do
      stored = %{thread_id: "t1", last_state: "Awaiting Review", last_run_at: "2026-09-21T11:40:00Z"}

      prompt = PromptBuilder.build_resume_prompt(issue, stored)

      assert prompt =~ "GEN-6"
      assert prompt =~ "Awaiting Review"
      assert prompt =~ "Executing"
      assert prompt =~ "2026-09-21T11:40:00Z"
      assert prompt =~ "resuming"
    end

    test "still renders when there is no stored transition", %{issue: issue} do
      prompt = PromptBuilder.build_resume_prompt(issue, nil)

      assert prompt =~ "GEN-6"
      assert prompt =~ "Executing"
      refute prompt =~ "{{"
    end

    test "a workflow-supplied template overrides the default", %{issue: issue} do
      workflow_file = Workflow.workflow_file_path()

      write_workflow_file!(workflow_file,
        codex_resume_prompt: "CUSTOM RESUME for {{ issue.identifier }} in {{ issue.state }}"
      )

      prompt = PromptBuilder.build_resume_prompt(issue, nil)

      assert prompt =~ "CUSTOM RESUME for GEN-6 in Executing"
    end
  end
end
