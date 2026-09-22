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
      commented_at = ~U[2026-09-21 11:40:00Z]

      assert :ok =
               ThreadStore.save(workspace, "thread-abc", %{
                 issue_state: "Executing",
                 latest_comment_at: commented_at
               })

      assert %{
               thread_id: "thread-abc",
               last_state: "Executing",
               last_comment_at: "2026-09-21T11:40:00Z",
               last_run_at: last_run_at
             } = ThreadStore.load(workspace)

      assert {:ok, _, _} = DateTime.from_iso8601(last_run_at)
    end

    test "a work item with no comments records no watermark", %{workspace: workspace} do
      :ok = ThreadStore.save(workspace, "thread-abc", %{issue_state: "Scoped", latest_comment_at: nil})

      assert %{last_comment_at: nil} = ThreadStore.load(workspace)
    end

    test "save overwrites the previous binding", %{workspace: workspace} do
      :ok = ThreadStore.save(workspace, "thread-old", %{issue_state: "Scoped"})
      :ok = ThreadStore.save(workspace, "thread-new", %{issue_state: "Executing"})

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
      assert :ok = ThreadStore.save(workspace, "thread-abc", %{issue_state: "Executing"}, "worker-1")
      refute File.exists?(ThreadStore.path(workspace))
      assert ThreadStore.load(workspace, "worker-1") == nil
    end

    test "the advertised tool set is recorded with the thread", %{workspace: workspace} do
      :ok =
        ThreadStore.save(workspace, "thread-abc", %{
          issue_state: "Scoped",
          tool_names: ["job_submit", "linear_graphql"]
        })

      assert %{tool_names: ["job_submit", "linear_graphql"]} = ThreadStore.load(workspace)
    end

    test "an older record without a tool set still loads", %{workspace: workspace} do
      path = ThreadStore.path(workspace)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(%{"thread_id" => "thread-abc", "last_state" => "Scoped"}))

      assert %{thread_id: "thread-abc", tool_names: nil} = ThreadStore.load(workspace)
    end

    test "the record lives inside the workspace so cleanup removes it", %{workspace: workspace} do
      :ok = ThreadStore.save(workspace, "thread-abc", %{issue_state: "Executing"})
      assert String.starts_with?(ThreadStore.path(workspace), workspace)
    end
  end

  describe "resume prompt" do
    setup do
      issue = %Issue{
        id: "issue-1",
        identifier: "GEN-6",
        title: "Measure something",
        state: "Scoped",
        description: "body",
        url: "https://linear.app/x/issue/GEN-6"
      }

      {:ok, issue: issue}
    end

    test "declares the current state and nothing else", %{issue: issue} do
      stored = %{thread_id: "t1", last_state: "Awaiting Review", last_run_at: "2026-09-21T11:40:00Z"}

      assert PromptBuilder.build_resume_prompt(issue, stored) ==
               "当前 Issue 生命周期状态被设置为：Scoped\n"
    end

    test "says the same thing when the state did not change", %{issue: issue} do
      stored = %{thread_id: "t1", last_state: "Scoped", last_run_at: "2026-09-21T11:40:00Z"}

      assert PromptBuilder.build_resume_prompt(issue, stored) ==
               "当前 Issue 生命周期状态被设置为：Scoped\n"
    end

    test "never narrates a transition or the agent's own memory", %{issue: issue} do
      stored = %{thread_id: "t1", last_state: "Awaiting Review", last_run_at: "2026-09-21T11:40:00Z"}

      for stored_thread <- [stored, nil] do
        prompt = PromptBuilder.build_resume_prompt(issue, stored_thread)

        refute prompt =~ ~r/moved from/i
        refute prompt =~ "Awaiting Review"
        refute prompt =~ ~r/context|memory|上下文|记忆/i
        refute prompt =~ ~r/workpad|scratchpad/i
        refute prompt =~ "{{"
      end
    end

    test "does not list tools, which would read as the only ones available", %{issue: issue} do
      prompt = PromptBuilder.build_resume_prompt(issue, nil)

      refute prompt =~ "request_state_change"
      refute prompt =~ "job_submit"
    end

    test "points at new comments only when the watermark moved", %{issue: issue} do
      issue = %{issue | latest_comment_at: ~U[2026-09-21 12:00:00Z]}

      stale = %{thread_id: "t1", last_comment_at: "2026-09-21T11:40:00Z"}
      current = %{thread_id: "t1", last_comment_at: "2026-09-21T12:00:00Z"}

      assert PromptBuilder.build_resume_prompt(issue, stale) =~ "Issue 有新评论"
      refute PromptBuilder.build_resume_prompt(issue, current) =~ "Issue 有新评论"
    end

    test "says nothing about comments on a work item that has none", %{issue: issue} do
      stored = %{thread_id: "t1", last_comment_at: nil}

      refute PromptBuilder.build_resume_prompt(issue, stored) =~ "评论"
    end

    test "reports comments once when there is no watermark yet", %{issue: issue} do
      # Missing watermark means we cannot tell, and a wasted read costs less
      # than the agent never seeing the answer it asked for.
      issue = %{issue | latest_comment_at: ~U[2026-09-21 12:00:00Z]}

      assert PromptBuilder.build_resume_prompt(issue, nil) =~ "Issue 有新评论"
    end

    test "announces job submission only in a state the config gates jobs to", %{issue: issue} do
      write_workflow_file!(Workflow.workflow_file_path(), jobs_gated_states: ["Executing"])

      refute PromptBuilder.build_resume_prompt(issue, nil) =~ "长时作业"
      assert PromptBuilder.build_resume_prompt(%{issue | state: "Executing"}, nil) =~ "长时作业"
    end

    test "stays silent about jobs when no state gates them", %{issue: issue} do
      refute PromptBuilder.build_resume_prompt(%{issue | state: "Executing"}, nil) =~ "长时作业"
    end

    test "a workflow-supplied template overrides the default", %{issue: issue} do
      write_workflow_file!(Workflow.workflow_file_path(),
        codex_resume_prompt: "CUSTOM RESUME for {{ issue.identifier }} in {{ issue.state }}"
      )

      assert PromptBuilder.build_resume_prompt(issue, nil) =~ "CUSTOM RESUME for GEN-6 in Scoped"
    end
  end
end
