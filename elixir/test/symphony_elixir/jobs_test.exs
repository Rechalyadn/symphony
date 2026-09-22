defmodule SymphonyElixir.JobsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Jobs.{AgentTool, Registry}

  setup do
    jobs_root =
      Path.join(System.tmp_dir!(), "symphony-jobs-#{System.unique_integer([:positive])}")

    workspace = Path.join(jobs_root, "workspace")
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      jobs_gated_states: ["Executing"],
      jobs_root: jobs_root,
      jobs_heartbeat_ms: 200,
      jobs_max_runtime_s: 30
    )

    issue = %Issue{
      id: "issue-job-#{System.unique_integer([:positive])}",
      identifier: "GEN-20",
      title: "Run a long computation",
      state: "Executing",
      labels: ["symphony"]
    }

    on_exit(fn ->
      Registry.release(issue.id)
      File.rm_rf(jobs_root)
    end)

    {:ok, issue: issue, workspace: workspace, jobs_root: jobs_root}
  end

  defp run(tool, args, context) do
    AgentTool.execute(tool, args, issue: context.issue, workspace: context.workspace)
  end

  defp payload(response), do: Jason.decode!(response["output"])

  describe "the job slot" do
    test "a work item with no job reports an empty slot", context do
      response = run("job_status", %{}, context)

      assert response["success"] == true
      assert payload(response)["job"] == nil
    end

    test "submitting runs the command and finishing is observable", context do
      submit = run("job_submit", %{"command" => "echo hello-from-job", "label" => "smoke"}, context)

      assert submit["success"] == true
      assert payload(submit)["job"]["status"] == "running"

      wait = run("job_wait", %{"timeout_s" => 10}, context)

      assert payload(wait)["finished"] == true
      assert payload(wait)["job"]["exit_status"] == 0
      assert payload(wait)["log_tail"] =~ "hello-from-job"
    end

    test "a second submit while one runs is refused, not queued", context do
      # Code-mode lets the agent call a tool repeatedly inside one JS block, so
      # this has to be refused at the write, not in the protocol text.
      assert run("job_submit", %{"command" => "sleep 5"}, context)["success"] == true

      second = run("job_submit", %{"command" => "sleep 5"}, context)

      assert second["success"] == false
      assert payload(second)["error"]["message"] =~ "already has a job running"

      run("job_cancel", %{}, context)
    end

    test "many submits in a row still leave exactly one job", context do
      responses = Enum.map(1..5, fn _ -> run("job_submit", %{"command" => "sleep 5"}, context) end)

      assert Enum.count(responses, & &1["success"]) == 1
      assert %{status: :running} = Registry.get(context.issue.id)

      run("job_cancel", %{}, context)
    end

    test "job_wait returns unfinished rather than blocking forever", context do
      assert run("job_submit", %{"command" => "sleep 30"}, context)["success"] == true

      wait = run("job_wait", %{"timeout_s" => 1}, context)

      assert payload(wait)["finished"] == false
      assert payload(wait)["job"]["status"] == "running"

      run("job_cancel", %{}, context)
    end

    test "cancelling stops the job", context do
      assert run("job_submit", %{"command" => "sleep 30"}, context)["success"] == true

      assert payload(run("job_cancel", %{"reason" => "changed my mind"}, context))["cancelled"] == true

      assert {:ok, entry} = await_finished(context.issue.id)
      assert entry.status == :killed
    end

    test "a failing command is reported with its exit status", context do
      assert run("job_submit", %{"command" => "echo boom >&2; exit 3"}, context)["success"] == true

      wait = run("job_wait", %{"timeout_s" => 10}, context)

      assert payload(wait)["job"]["exit_status"] == 3
      assert payload(wait)["log_tail"] =~ "boom"
    end
  end

  describe "state gating" do
    test "job_submit is refused outside the gated states", context do
      context = put_in(context.issue.state, "Scoped")

      response = run("job_submit", %{"command" => "echo nope"}, context)

      assert response["success"] == false
      assert payload(response)["error"]["message"] =~ "Scoped"
      assert Registry.get(context.issue.id) == nil
    end

    test "job_status still works outside the gated states", context do
      # An agent picking up last round's result has to be able to read it
      # before it is allowed to start anything new.
      assert run("job_submit", %{"command" => "echo done"}, context)["success"] == true
      assert run("job_wait", %{"timeout_s" => 10}, context)["success"] == true

      scoped = put_in(context.issue.state, "Scoped")
      response = run("job_status", %{}, scoped)

      assert response["success"] == true
      assert payload(response)["job"]["status"] == "exited"
    end
  end

  describe "lifetime" do
    test "a job outlives the process that asked for it", context do
      # This is the whole reason jobs are not started by the agent: an Erlang
      # port dies with its owner, and the agent's session dies routinely.
      parent = self()

      caller =
        spawn(fn ->
          send(parent, {:submitted, run("job_submit", %{"command" => "sleep 3; echo survived"}, context)})
        end)

      assert_receive {:submitted, submit}, 5_000
      assert submit["success"] == true

      ref = Process.monitor(caller)
      assert_receive {:DOWN, ^ref, :process, ^caller, _}, 5_000

      assert %{status: :running} = Registry.get(context.issue.id)

      wait = run("job_wait", %{"timeout_s" => 15}, context)
      assert payload(wait)["finished"] == true
      assert payload(wait)["log_tail"] =~ "survived"
    end

    test "progress heartbeats reach the orchestrator recipient", context do
      response =
        AgentTool.execute("job_submit", %{"command" => "echo tick; sleep 2"},
          issue: context.issue,
          workspace: context.workspace,
          codex_update_recipient: self()
        )

      assert response["success"] == true

      assert_receive {:codex_worker_update, issue_id, update}, 5_000
      assert issue_id == context.issue.id

      # These two keys are what the orchestrator's handle_info matches on, and
      # the event name must never be one it reads as "needs a human".
      assert %{event: :job_progress, timestamp: %DateTime{}} = update
      refute update.event in [:turn_input_required, :approval_required]
      assert Map.has_key?(update.payload, :elapsed_s)

      run("job_cancel", %{}, context)
    end

    test "the slot is recorded on disk so a restart can see it", context do
      assert run("job_submit", %{"command" => "sleep 5"}, context)["success"] == true

      path = Registry.record_path(context.issue.id)
      assert File.exists?(path)

      record = path |> File.read!() |> Jason.decode!()
      assert record["status"] == "running"
      assert record["command"] == "sleep 5"

      run("job_cancel", %{}, context)
    end

    test "a record left as running after a restart is recovered as orphaned", context do
      # The BEAM that owned the port is gone, so the job cannot still be
      # running; the agent's next job_status has to say so rather than hang.
      File.mkdir_p!(context.jobs_root)

      File.write!(
        Registry.record_path(context.issue.id),
        Jason.encode!(%{
          "job_id" => "job-stale",
          "issue_id" => context.issue.id,
          "identifier" => "GEN-20",
          "command" => "sleep 99999",
          "label" => "before the crash",
          "compute" => "heavy",
          "status" => "running",
          "started_at" => "2026-09-21T00:00:00Z",
          "log_file" => Path.join(context.jobs_root, "stale.log")
        })
      )

      :ok = Registry.recover()

      assert %{status: :orphaned, job_id: "job-stale"} = await_orphaned(context.issue.id)
    end

    test "a finished job is still there after a restart, until it is read", context do
      # The slot holds the answer the computation produced. Dropping it on
      # restart would lose that result with no way to get it back.
      assert run("job_submit", %{"command" => "echo persisted"}, context)["success"] == true
      assert run("job_wait", %{"timeout_s" => 10}, context)["success"] == true

      :ets.delete(Registry, context.issue.id)
      assert Registry.get(context.issue.id) == nil

      :ok = Registry.recover()

      assert %{status: :exited, exit_status: 0} = Registry.get(context.issue.id)
    end

    test "releasing the slot clears it for the next round", context do
      assert run("job_submit", %{"command" => "true"}, context)["success"] == true
      assert run("job_wait", %{"timeout_s" => 10}, context)["success"] == true

      :ok = Registry.release(context.issue.id)

      assert Registry.get(context.issue.id) == nil
      assert run("job_submit", %{"command" => "true"}, context)["success"] == true
    end
  end

  defp await_orphaned(issue_id, attempts \\ 50) do
    case Registry.get(issue_id) do
      %{status: :orphaned} = entry -> entry
      _ when attempts > 0 -> Process.sleep(20) && await_orphaned(issue_id, attempts - 1)
      other -> other
    end
  end

  defp await_finished(issue_id, attempts \\ 50) do
    case Registry.get(issue_id) do
      %{status: status} = entry when status != :running -> {:ok, entry}
      _ when attempts > 0 -> Process.sleep(50) && await_finished(issue_id, attempts - 1)
      other -> {:error, other}
    end
  end
end
