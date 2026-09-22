defmodule SymphonyElixir.DelayedStateChangeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.{Intents, StateChangeTool}
  alias SymphonyElixir.AgentTools

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-delayed-#{System.unique_integer([:positive])}",
      identifier: "GEN-42",
      title: "Recompute the momentum factor",
      state: "Scoped",
      url: "https://linear.app/x/issue/GEN-42"
    }

    on_exit(fn ->
      Intents.clear(issue.id)
      Application.delete_env(:symphony_elixir, :memory_tracker_states)
      Application.delete_env(:symphony_elixir, :memory_tracker_state_changes)
    end)

    {:ok, issue: issue}
  end

  describe "Intents" do
    test "an unrequested issue has no intent", %{issue: issue} do
      assert Intents.peek(issue.id) == nil
    end

    test "put then take round-trips and consumes", %{issue: issue} do
      assert :ok = Intents.put(issue.id, "Awaiting Review", "ready for口径确认")

      assert %{to_state: "Awaiting Review", reason: "ready for口径确认", requested_at: %DateTime{}} =
               Intents.peek(issue.id)

      assert %{to_state: "Awaiting Review"} = Intents.take(issue.id)
      assert Intents.peek(issue.id) == nil
    end

    test "a second request replaces the first", %{issue: issue} do
      :ok = Intents.put(issue.id, "Awaiting Review", nil)
      :ok = Intents.put(issue.id, "Awaiting Input", nil)

      assert %{to_state: "Awaiting Input"} = Intents.peek(issue.id)
    end

    test "intents are keyed per issue", %{issue: issue} do
      :ok = Intents.put(issue.id, "Awaiting Review", nil)

      assert Intents.peek("some-other-issue") == nil
    end
  end

  describe "request_state_change" do
    test "is advertised alongside the tracker's own tools" do
      names = Enum.map(AgentTools.bind().tool_specs, & &1["name"])

      assert "request_state_change" in names
    end

    test "registers the state without touching the tracker", %{issue: issue} do
      response = StateChangeTool.execute("request_state_change", %{"to_state" => "Awaiting Review"}, issue: issue)

      assert response["success"] == true
      assert %{"registered" => true, "from_state" => "Scoped", "to_state" => "Awaiting Review"} = Jason.decode!(response["output"])

      assert Application.get_env(:symphony_elixir, :memory_tracker_state_changes, []) == []
      assert %{to_state: "Awaiting Review"} = Intents.peek(issue.id)
    end

    test "returns the shape the app-server requires", %{issue: issue} do
      response = StateChangeTool.execute("request_state_change", %{"to_state" => "Executing"}, issue: issue)

      assert is_boolean(response["success"])
      assert [%{"type" => "inputText", "text" => text}] = response["contentItems"]
      assert text == response["output"]
    end

    test "rejects a blank state", %{issue: issue} do
      response = StateChangeTool.execute("request_state_change", %{"to_state" => "   "}, issue: issue)

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "non-empty"
      assert Intents.peek(issue.id) == nil
    end

    test "rejects arguments that are not an object", %{issue: issue} do
      response = StateChangeTool.execute("request_state_change", "Awaiting Review", issue: issue)

      assert response["success"] == false
      assert Intents.peek(issue.id) == nil
    end

    test "rejects a state the tracker does not have", %{issue: issue} do
      Application.put_env(:symphony_elixir, :memory_tracker_states, ["Scoped", "Awaiting Review", "Executing"])

      response = StateChangeTool.execute("request_state_change", %{"to_state" => "Awating Review"}, issue: issue)

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "Awaiting Review"
      assert Intents.peek(issue.id) == nil
    end

    test "matches a known state regardless of case", %{issue: issue} do
      Application.put_env(:symphony_elixir, :memory_tracker_states, ["Awaiting Review"])

      response = StateChangeTool.execute("request_state_change", %{"to_state" => "awaiting review"}, issue: issue)

      assert response["success"] == true
      assert %{to_state: "awaiting review"} = Intents.peek(issue.id)
    end

    test "registers anyway when the tracker cannot be listed", %{issue: issue} do
      # An unreachable tracker must not block the agent from finishing its run.
      Application.delete_env(:symphony_elixir, :memory_tracker_states)

      response = StateChangeTool.execute("request_state_change", %{"to_state" => "Whatever"}, issue: issue)

      assert response["success"] == true
    end

    test "fails when no work item is bound to the session" do
      response = StateChangeTool.execute("request_state_change", %{"to_state" => "Awaiting Review"}, [])

      assert response["success"] == false
    end

    test "routes through the bound tool set rather than the tracker adapter", %{issue: issue} do
      binding = AgentTools.bind()

      response = AgentTools.execute(binding, "request_state_change", %{"to_state" => "Executing"}, issue: issue)

      assert response["success"] == true
      assert %{to_state: "Executing"} = Intents.peek(issue.id)
    end
  end

  describe "AgentRunner applies a registered state change" do
    setup do
      test_root =
        Path.join(System.tmp_dir!(), "symphony-delayed-state-#{System.unique_integer([:positive])}")

      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(test_root)

      on_exit(fn ->
        File.rm_rf(test_root)
        Application.delete_env(:symphony_elixir, :memory_tracker_state_changes)
      end)

      {:ok, test_root: test_root, workspace_root: workspace_root, codex_binary: codex_binary}
    end

    test "ends the run at the registering turn and moves the work item afterwards", context do
      write_fake_codex!(context.codex_binary, :complete)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: context.workspace_root,
        codex_command: "#{context.codex_binary} app-server",
        max_turns: 5
      )

      issue = active_issue()

      # The fetcher always reports the work item as active, so only the
      # registered intent can stop the turn loop.
      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: fn _ -> {:ok, [issue]} end)

      assert Application.get_env(:symphony_elixir, :memory_tracker_state_changes) == [
               {issue.id, "Awaiting Review"}
             ]

      assert Intents.peek(issue.id) == nil
    end

    test "leaves the work item alone when the run does not return cleanly", context do
      write_fake_codex!(context.codex_binary, :die)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: context.workspace_root,
        codex_command: "#{context.codex_binary} app-server",
        max_turns: 5
      )

      issue = active_issue()

      assert_raise RuntimeError, fn ->
        AgentRunner.run(issue, nil, issue_state_fetcher: fn _ -> {:ok, [issue]} end)
      end

      assert Application.get_env(:symphony_elixir, :memory_tracker_state_changes, []) == []
    end
  end

  defp active_issue do
    %Issue{
      id: "issue-delayed-run",
      identifier: "GEN-43",
      title: "Stay active forever",
      description: "The tracker never reports this one as finished",
      state: "Scoped",
      url: "https://linear.app/x/issue/GEN-43",
      dispatchable: true
    }
  end

  # Answers the handshake, then calls request_state_change during turn 1.
  defp write_fake_codex!(path, ending) do
    after_tool_result =
      case ending do
        :complete -> ~S(printf '%s\n' '{"method":"turn/completed"}')
        :die -> "exit 1"
      end

    File.write!(path, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          ;;
        3)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-delayed"}}}'
          ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-delayed"}}}'
          printf '%s\\n' '{"id":77,"method":"item/tool/call","params":{"tool":"request_state_change","arguments":{"to_state":"Awaiting Review","reason":"ready for review"}}}'
          ;;
        5)
          #{after_tool_result}
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
