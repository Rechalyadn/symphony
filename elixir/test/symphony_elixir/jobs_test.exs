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

    test "cancelling kills the computation, not just the port", context do
      # The computation is a child of the shell we spawn. Closing the port alone
      # leaves it running, so this checks the grandchild is actually gone.
      pid_file = Path.join(context.workspace, "child.pid")
      command = "sleep 30 & echo $! > #{pid_file}; wait"

      assert run("job_submit", %{"command" => command}, context)["success"] == true
      child = await_file(pid_file)
      assert Registry.os_process_alive?(child)

      assert payload(run("job_cancel", %{"reason" => "changed my mind"}, context))["cancelled"] == true

      assert {:ok, entry} = await_finished(context.issue.id)
      assert entry.status == :killed
      assert await_dead(child)
    end

    test "a job past its runtime cap is killed", context do
      pid_file = Path.join(context.workspace, "capped.pid")
      command = "sleep 30 & echo $! > #{pid_file}; wait"

      assert run("job_submit", %{"command" => command, "max_runtime_s" => 1}, context)["success"] == true
      child = await_file(pid_file)

      wait = run("job_wait", %{"timeout_s" => 10}, context)

      assert payload(wait)["job"]["status"] == "killed"
      assert await_dead(child)
    end

    test "cancelling a finished job reports it and changes nothing", context do
      assert run("job_submit", %{"command" => "true"}, context)["success"] == true
      assert run("job_wait", %{"timeout_s" => 10}, context)["success"] == true

      response = payload(run("job_cancel", %{}, context))

      assert response["cancelled"] == false
      assert response["job"]["status"] == "exited"
    end

    test "cancelling with no job on record is a harmless no-op", context do
      assert payload(run("job_cancel", %{}, context))["cancelled"] == false
    end

    test "a failing command is reported with its exit status", context do
      assert run("job_submit", %{"command" => "echo boom >&2; exit 3"}, context)["success"] == true

      wait = run("job_wait", %{"timeout_s" => 10}, context)

      assert payload(wait)["job"]["exit_status"] == 3
      assert payload(wait)["log_tail"] =~ "boom"
    end
  end

  describe "argument and binding errors" do
    test "a blank command is refused", context do
      response = run("job_submit", %{"command" => "   "}, context)

      assert response["success"] == false
      assert payload(response)["error"]["message"] =~ "non-empty"
    end

    test "arguments that are not an object are treated as empty", context do
      assert run("job_submit", "sleep 1", context)["success"] == false
    end

    test "job_wait needs a positive timeout", context do
      assert run("job_wait", %{"timeout_s" => 0}, context)["success"] == false
    end

    test "job_wait with nothing to wait for says so", context do
      response = run("job_wait", %{"timeout_s" => 1}, context)

      assert response["success"] == false
      assert payload(response)["error"]["message"] =~ "no job"
    end

    test "a session without a work item gets a clear refusal", context do
      response = AgentTool.execute("job_status", %{}, workspace: context.workspace)

      assert response["success"] == false
    end

    test "a session without a workspace cannot submit", context do
      response = AgentTool.execute("job_submit", %{"command" => "true"}, issue: context.issue)

      assert response["success"] == false
      assert payload(response)["error"]["message"] =~ "workspace"
    end

    test "an unknown tool name is refused", context do
      assert run("job_explode", %{}, context)["success"] == false
    end

    test "a runner that cannot start frees the slot again", context do
      # A jobs root under a regular file can hold neither the record nor the
      # log, so the runner fails to start; the slot must not stay claimed.
      blocker = Path.join(context.jobs_root, "not-a-directory")
      File.write!(blocker, "")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        jobs_gated_states: ["Executing"],
        jobs_root: Path.join(blocker, "jobs")
      )

      response =
        capture_log(fn -> send(self(), {:response, run("job_submit", %{"command" => "true"}, context)}) end)
        |> then(fn log ->
          assert log =~ "Unable to record job"
          assert_received {:response, response}
          response
        end)

      assert response["success"] == false
      assert payload(response)["error"]["message"] =~ "could not start"
      assert Registry.get(context.issue.id) == nil
    end
  end

  describe "compute budget" do
    test "the compute tier comes from the label and its budget is enforced", context do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        jobs_gated_states: ["Executing"],
        jobs_root: context.jobs_root,
        jobs_max_concurrent_by_compute: %{"heavy" => 1}
      )

      heavy = %{context | issue: %{context.issue | labels: ["symphony", "compute:heavy"]}}
      other_issue = %{heavy.issue | id: heavy.issue.id <> "-b", identifier: "GEN-21"}
      other = %{heavy | issue: other_issue}

      on_exit(fn -> Registry.release(other_issue.id) end)

      assert payload(run("job_submit", %{"command" => "sleep 10"}, heavy))["job"]["compute"] == "heavy"

      refused = run("job_submit", %{"command" => "sleep 10"}, other)

      assert refused["success"] == false
      assert payload(refused)["error"]["message"] =~ "heavy"

      run("job_cancel", %{}, heavy)
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

    test "a work item with no state cannot submit", context do
      assert run("job_submit", %{"command" => "true"}, put_in(context.issue.state, nil))["success"] == false
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

  describe "registry" do
    test "await on a finished job returns it at once", context do
      assert run("job_submit", %{"command" => "true"}, context)["success"] == true
      assert {:ok, %{status: :exited}} = Registry.await(context.issue.id, 10_000)

      assert {:ok, %{status: :exited}} = Registry.await(context.issue.id, 0)
    end

    test "await with no job on record says so", context do
      assert Registry.await(context.issue.id, 0) == :no_job
    end

    test "a stale completion message is not mistaken for the current job", context do
      # An earlier await that timed out can leave its completion message in the
      # mailbox; the next await must wait on the job running now.
      send(self(), {:job_finished, context.issue.id, %{status: :exited, stale: true}})

      assert run("job_submit", %{"command" => "sleep 5"}, context)["success"] == true
      assert Registry.await(context.issue.id, 200) == :timeout

      run("job_cancel", %{}, context)
    end

    test "attaching to a slot that is gone does nothing", context do
      :ok = Registry.attach_runner(context.issue.id, self())
      :ok = Registry.attach_os_pid(context.issue.id, 12_345)
      _ = :sys.get_state(Registry)

      assert Registry.get(context.issue.id) == nil
    end

    test "recovery tolerates records with odd timestamps", context do
      File.mkdir_p!(context.jobs_root)

      for {suffix, started_at} <- [{"bad", "yesterday"}, {"missing", nil}] do
        issue_id = context.issue.id <> "-" <> suffix
        on_exit(fn -> Registry.release(issue_id) end)

        File.write!(
          Registry.record_path(issue_id),
          Jason.encode!(%{"job_id" => "job-#{suffix}", "issue_id" => issue_id, "status" => "exited", "started_at" => started_at})
        )
      end

      :ok = Registry.recover()

      assert %{status: :exited, started_at: %DateTime{}} = Registry.get(context.issue.id <> "-bad")
      assert %{status: :exited, started_at: %DateTime{}} = Registry.get(context.issue.id <> "-missing")
    end

    test "an orphaned job reports whether its process is still alive", context do
      assert Registry.os_process_alive?(String.to_integer(System.pid()))
      refute Registry.os_process_alive?(nil)

      File.mkdir_p!(context.jobs_root)

      File.write!(
        Registry.record_path(context.issue.id),
        Jason.encode!(%{
          "job_id" => "job-detached",
          "issue_id" => context.issue.id,
          "status" => "running",
          "started_at" => "2026-09-21T00:00:00Z",
          "log_file" => Path.join(context.jobs_root, "detached.log"),
          "os_pid" => String.to_integer(System.pid())
        })
      )

      :ok = Registry.recover()

      assert payload(run("job_status", %{}, context))["job"]["still_running_detached"] == true
    end
  end

  describe "runner" do
    test "stopping the supervisor child kills the computation", context do
      pid_file = Path.join(context.workspace, "shutdown.pid")

      assert run("job_submit", %{"command" => "sleep 30 & echo $! > #{pid_file}; wait"}, context)["success"] == true
      child = await_file(pid_file)
      %{runner: runner} = await_runner(context.issue.id)

      :ok = DynamicSupervisor.terminate_child(SymphonyElixir.Jobs.Supervisor, runner)

      assert await_dead(child)
    end

    test "a port that dies without an exit status leaves the slot orphaned", context do
      assert run("job_submit", %{"command" => "sleep 30"}, context)["success"] == true
      %{runner: runner} = await_runner(context.issue.id)

      ref = Process.monitor(runner)
      %{port: port} = :sys.get_state(runner)
      send(runner, {:EXIT, port, :killed})

      assert_receive {:DOWN, ^ref, :process, ^runner, _reason}, 5_000
      assert %{status: :orphaned} = Registry.get(context.issue.id)
    end

    test "shutting down after the job already exited does not crash", context do
      # The port can close on its own between a stop request and the runner
      # handling it; closing it again must not take the runner down mid-kill.
      assert run("job_submit", %{"command" => "sleep 0.2"}, context)["success"] == true
      %{runner: runner} = await_runner(context.issue.id)

      :ok = :sys.suspend(runner)
      Process.sleep(600)

      ref = Process.monitor(runner)
      :ok = DynamicSupervisor.terminate_child(SymphonyElixir.Jobs.Supervisor, runner)

      assert_receive {:DOWN, ^ref, :process, ^runner, :shutdown}, 5_000
    end

    test "unrelated messages are ignored", context do
      assert run("job_submit", %{"command" => "sleep 5"}, context)["success"] == true
      %{runner: runner} = await_runner(context.issue.id)

      send(runner, :something_else)
      _ = :sys.get_state(runner)

      assert Process.alive?(runner)
      run("job_cancel", %{}, context)
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

  defp await_runner(issue_id, attempts \\ 100) do
    case Registry.get(issue_id) do
      %{runner: runner} = entry when is_pid(runner) -> entry
      _ when attempts > 0 -> Process.sleep(20) && await_runner(issue_id, attempts - 1)
    end
  end

  defp await_file(path, attempts \\ 100) do
    case File.read(path) do
      {:ok, contents} when contents != "" -> contents |> String.trim() |> String.to_integer()
      _ when attempts > 0 -> Process.sleep(20) && await_file(path, attempts - 1)
    end
  end

  defp await_dead(os_pid, attempts \\ 100) do
    cond do
      not Registry.os_process_alive?(os_pid) -> true
      attempts > 0 -> Process.sleep(20) && await_dead(os_pid, attempts - 1)
      true -> false
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
