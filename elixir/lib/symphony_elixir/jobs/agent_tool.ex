defmodule SymphonyElixir.Jobs.AgentTool do
  @moduledoc """
  The four job tools an agent gets.

  None of them takes a job id. The work item the session is bound to is the
  address, so an agent cannot reach another issue's job and cannot lose track
  of its own.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Jobs.{Registry, Runner, Supervisor}
  alias SymphonyElixir.Tracker.Issue

  @submit "job_submit"
  @status "job_status"
  @wait "job_wait"
  @cancel "job_cancel"

  @max_log_tail_lines 200

  @spec tool_names() :: [String.t()]
  def tool_names, do: [@submit, @status, @wait, @cancel]

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      spec(@submit, submit_description(), %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["command"],
        "properties" => %{
          "command" => %{"type" => "string", "description" => "Shell command to run in the workspace. It keeps running after your turn ends."},
          "label" => %{"type" => ["string", "null"], "description" => "Short name for this run, shown in progress updates."},
          "max_runtime_s" => %{"type" => ["integer", "null"], "description" => "Hard kill after this many seconds. Capped by jobs.max_runtime_s."}
        }
      }),
      spec(@status, "Report this work item's job slot: what has run, what is running now, and the tail of its output. Read-only and available in every state.", %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{}
      }),
      spec(@wait, wait_description(), %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["timeout_s"],
        "properties" => %{
          "timeout_s" => %{"type" => "integer", "description" => "How long to block before returning with the job still running."},
          "log_tail_lines" => %{"type" => ["integer", "null"], "description" => "Lines of output to return (default 40)."}
        }
      }),
      spec(@cancel, "Terminate this work item's job. Safe in every state.", %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "reason" => %{"type" => ["string", "null"], "description" => "Why, for the run log."}
        }
      })
    ]
  end

  defp submit_description do
    """
    Submit a long-running computation. Symphony hosts the process, so it
    survives your turn ending, a restart of your session, and `agent.max_turns`.

    Only one job per work item at a time. A parameter sweep is either one job
    that fans out inside the script, or serial steps that record their own
    progress; a second submit while one is running is refused.

    Available only in the states the workflow gates jobs to. A refusal
    elsewhere means you should ask for execution approval first.
    """
  end

  defp wait_description do
    """
    Block until this work item's job ends or `timeout_s` passes, then return its
    status and the tail of its output.

    Do not poll, and do not sleep in the shell. This is how you wait.
    """
  end

  defp spec(name, description, schema) do
    %{"type" => "function", "name" => name, "description" => description, "inputSchema" => schema}
  end

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) do
    case Keyword.get(opts, :issue) do
      %Issue{} = issue -> dispatch(tool, normalize(arguments), issue, opts)
      _ -> failure("Symphony did not bind a work item to this session, so there is no job slot to act on.")
    end
  end

  defp dispatch(@submit, args, issue, opts), do: submit(args, issue, opts)
  defp dispatch(@status, _args, issue, _opts), do: report(issue)
  defp dispatch(@wait, args, issue, _opts), do: wait(args, issue)
  defp dispatch(@cancel, args, issue, _opts), do: cancel(args, issue)
  defp dispatch(other, _args, _issue, _opts), do: failure("Unsupported dynamic tool: #{inspect(other)}.")

  # The gate lives here rather than in the advertised tool list so `job_status`
  # still works in every state: an agent picking up a finished computation needs
  # to read the result before it can ask for anything.
  defp submit(args, %Issue{state: state} = issue, opts) do
    jobs = Config.settings!().jobs

    cond do
      not gated_state?(jobs.gated_states, state) ->
        failure("`job_submit` is not available while this work item is in `#{state}`. Post a comment saying what you want to run and request the state that allows it.")

      not is_binary(args["command"]) or String.trim(args["command"]) == "" ->
        failure("`job_submit` requires a non-empty `command`.")

      true ->
        start_job(args, issue, jobs, opts)
    end
  end

  defp start_job(args, %Issue{} = issue, jobs, opts) do
    workspace = Keyword.get(opts, :workspace)

    if is_binary(workspace) do
      log_file = Path.join([jobs.root, "logs", "#{issue.identifier}-#{System.system_time(:second)}.log"])
      max_runtime_s = min(args["max_runtime_s"] || jobs.max_runtime_s, jobs.max_runtime_s)

      claim_and_start(issue, args, %{log_file: log_file, max_runtime_s: max_runtime_s, workspace: workspace}, opts)
    else
      failure("Symphony did not bind a workspace to this session, so there is nowhere to run the job.")
    end
  end

  defp claim_and_start(%Issue{} = issue, args, run, opts) do
    attrs = %{
      command: String.trim(args["command"]),
      label: args["label"],
      identifier: issue.identifier,
      compute: compute_tier(issue),
      log_file: run.log_file
    }

    case Registry.claim(issue.id, attrs) do
      {:ok, entry} -> spawn_runner(issue, entry, run, opts)
      {:error, {:already_running, running}} -> failure("This work item already has a job running (#{running.label || running.job_id}). Wait for it with `job_wait`, or stop it with `job_cancel`.")
      {:error, {:compute_limit, compute, limit}} -> failure("The `#{compute}` compute budget is full (#{limit} running). Try again after one finishes.")
      {:error, :unavailable} -> failure("Symphony cannot host jobs right now. Report this in a work item comment and stop.")
    end
  end

  defp spawn_runner(%Issue{} = issue, entry, run, opts) do
    runner_opts = [
      issue_id: issue.id,
      identifier: issue.identifier,
      command: entry.command,
      workspace: run.workspace,
      log_file: run.log_file,
      max_runtime_s: run.max_runtime_s,
      recipient: Keyword.get(opts, :codex_update_recipient)
    ]

    case Supervisor.start_job(runner_opts) do
      {:ok, runner} ->
        Registry.attach_runner(issue.id, runner)

        Logger.info("Job submitted issue_identifier=#{issue.identifier} job_id=#{entry.job_id} label=#{inspect(entry.label)}")

        success(%{"submitted" => true, "job" => describe(%{entry | runner: runner}), "next" => "Call job_wait(60) first to confirm it did not fail on startup."})

      {:error, reason} ->
        Registry.finish(issue.id, :killed, nil)
        Registry.release(issue.id)
        failure("Symphony could not start the job: #{inspect(reason)}")
    end
  end

  defp report(%Issue{} = issue) do
    case Registry.get(issue.id) do
      nil -> success(%{"job" => nil, "note" => "This work item has no job on record."})
      entry -> success(%{"job" => describe(entry), "log_tail" => log_tail(entry, 40)})
    end
  end

  defp wait(args, %Issue{} = issue) do
    timeout_s = args["timeout_s"]
    lines = min(args["log_tail_lines"] || 40, @max_log_tail_lines)

    if is_integer(timeout_s) and timeout_s > 0 do
      do_wait(issue, timeout_s, lines)
    else
      failure("`job_wait` requires a positive `timeout_s`.")
    end
  end

  defp do_wait(%Issue{} = issue, timeout_s, lines) do
    case Registry.await(issue.id, timeout_s * 1_000) do
      {:ok, entry} -> success(%{"finished" => true, "job" => describe(entry), "log_tail" => log_tail(entry, lines)})
      :timeout -> success(%{"finished" => false, "job" => describe(Registry.get(issue.id)), "log_tail" => log_tail(Registry.get(issue.id), lines)})
      :no_job -> failure("This work item has no job to wait for.")
    end
  end

  defp cancel(args, %Issue{} = issue) do
    case Registry.get(issue.id) do
      %{status: :running, runner: runner} when is_pid(runner) ->
        Runner.cancel(runner, args["reason"] || "cancelled by agent")
        success(%{"cancelled" => true})

      %{} = entry ->
        success(%{"cancelled" => false, "job" => describe(entry), "note" => "That job had already finished."})

      nil ->
        success(%{"cancelled" => false, "note" => "This work item has no job to cancel."})
    end
  end

  defp compute_tier(%Issue{labels: labels}) when is_list(labels) do
    default = Config.settings!().jobs.default_compute

    Enum.find_value(labels, default, fn label ->
      case String.split(label, ~r{compute[:/]\s*}, parts: 2) do
        ["", tier] -> String.trim(tier)
        _ -> nil
      end
    end)
  end

  defp compute_tier(_issue), do: Config.settings!().jobs.default_compute

  defp gated_state?(gated_states, state) when is_list(gated_states) and is_binary(state) do
    normalized = state |> String.trim() |> String.downcase()
    Enum.any?(gated_states, &(&1 |> String.trim() |> String.downcase() == normalized))
  end

  defp gated_state?(_gated_states, _state), do: false

  defp describe(nil), do: nil

  defp describe(entry) do
    %{
      "job_id" => entry.job_id,
      "label" => entry.label,
      "command" => entry.command,
      "compute" => entry.compute,
      "status" => Atom.to_string(entry.status),
      "started_at" => DateTime.to_iso8601(entry.started_at),
      "finished_at" => entry.finished_at && DateTime.to_iso8601(entry.finished_at),
      "exit_status" => entry.exit_status,
      "still_running_detached" => entry.status == :orphaned and Registry.os_process_alive?(entry.os_pid)
    }
  end

  defp log_tail(nil, _lines), do: nil

  defp log_tail(entry, lines) do
    case File.read(entry.log_file) do
      {:ok, contents} ->
        contents |> String.split("\n", trim: true) |> Enum.take(-lines) |> Enum.join("\n")

      {:error, _reason} ->
        nil
    end
  end

  defp normalize(arguments) when is_map(arguments) do
    Map.new(arguments, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize(_arguments), do: %{}

  defp success(payload), do: response(true, payload)
  defp failure(message), do: response(false, %{"error" => %{"message" => message}})

  defp response(success, payload) do
    output = Jason.encode!(payload, pretty: true)

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end
end
