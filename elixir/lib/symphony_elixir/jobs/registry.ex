defmodule SymphonyElixir.Jobs.Registry do
  @moduledoc """
  The one job slot each work item has.

  A job is not an entity of its own: it is a slot on an issue, so every tool
  addresses it by the issue the session is already bound to and no job id ever
  reaches the agent. That removes a whole family of failure modes — a forgotten
  id, a stale id, a cold start that has to read a file before it can ask what is
  running, two jobs started for one issue.

  Claiming goes through the GenServer rather than straight into ETS because the
  agent drives tools from code-mode: it writes JavaScript that can call
  `job_submit` in a loop, so "only one job per issue" has to be enforced where
  the write happens, not in the protocol text the agent may ignore.

  The cost of the slot model: one job per issue at a time. A parameter sweep is
  either one job that fans out internally, or serial steps that record their own
  progress.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Config

  @table __MODULE__

  @type status :: :running | :exited | :killed | :orphaned
  @type entry :: %{
          job_id: String.t(),
          issue_id: String.t(),
          identifier: String.t() | nil,
          command: String.t(),
          label: String.t() | nil,
          compute: String.t(),
          status: status(),
          started_at: DateTime.t(),
          finished_at: DateTime.t() | nil,
          exit_status: integer() | nil,
          log_file: Path.t(),
          os_pid: integer() | nil,
          runner: pid() | nil,
          last_line: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{subscribers: %{}}, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    recover()
    {:noreply, state}
  end

  @doc """
  Reconciles on-disk records with reality after a restart.

  A record that says `running` cannot be: its process died with the BEAM that
  started it. Marking it orphaned is what makes the agent's next `job_status`
  tell the truth instead of leaving it waiting on something that will never
  finish.
  """
  @spec recover() :: :ok
  def recover do
    root = Config.settings!().jobs.root

    case File.ls(root) do
      {:ok, files} -> Enum.each(files, &recover_record(Path.join(root, &1)))
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Takes the issue's slot, or says why it could not.

  Serialized through the GenServer so two calls in one code-mode block cannot
  both win.
  """
  @type claim_error :: {:already_running, entry()} | {:compute_limit, String.t(), pos_integer()}

  @spec claim(String.t(), map()) :: {:ok, entry()} | {:error, claim_error()}
  def claim(issue_id, attrs) when is_binary(issue_id) do
    GenServer.call(__MODULE__, {:claim, issue_id, attrs})
  end

  @doc """
  The issue's slot as it stands, or `nil` when it has never held a job.
  """
  @spec get(String.t()) :: entry() | nil
  def get(issue_id) when is_binary(issue_id) do
    with true <- ready?(),
         [{^issue_id, entry}] <- :ets.lookup(@table, issue_id) do
      entry
    else
      _ -> nil
    end
  end

  @doc """
  Records the OS pid of the job's process group.

  Kept so that after a Symphony restart the record can say whether the
  computation is still running — the BEAM dying does not kill it, it just
  detaches it.
  """
  @spec attach_os_pid(String.t(), integer()) :: :ok
  def attach_os_pid(issue_id, os_pid) when is_binary(issue_id) and is_integer(os_pid) do
    if ready?(), do: GenServer.cast(__MODULE__, {:attach_os_pid, issue_id, os_pid})
    :ok
  end

  @doc """
  Attaches the runner process to a slot already claimed for `issue_id`.

  The slot is claimed before the runner starts, so that two concurrent submits
  cannot both get past the claim and then both spawn.
  """
  @spec attach_runner(String.t(), pid()) :: :ok
  def attach_runner(issue_id, runner) when is_binary(issue_id) and is_pid(runner) do
    if ready?(), do: GenServer.cast(__MODULE__, {:attach_runner, issue_id, runner})
    :ok
  end

  @doc """
  Records the running job's newest output line, for heartbeats and `job_status`.
  """
  @spec record_output(String.t(), String.t()) :: :ok
  def record_output(issue_id, line) when is_binary(issue_id) and is_binary(line) do
    if ready?(), do: GenServer.cast(__MODULE__, {:record_output, issue_id, line})
    :ok
  end

  @doc """
  Closes out a job and wakes anything waiting on it.
  """
  @spec finish(String.t(), status(), integer() | nil) :: :ok
  def finish(issue_id, status, exit_status) when is_binary(issue_id) do
    if ready?(), do: GenServer.call(__MODULE__, {:finish, issue_id, status, exit_status}), else: :ok
  end

  @doc """
  Frees a finished slot once the agent has read the result.
  """
  @spec release(String.t()) :: :ok
  def release(issue_id) when is_binary(issue_id) do
    if ready?(), do: GenServer.call(__MODULE__, {:release, issue_id}), else: :ok
  end

  @doc """
  Blocks until the issue's job ends, or until `timeout_ms` passes.

  Waiting here is deliberate: the caller is the agent runner's own process, and
  a blocked tool call is exactly how the agent sleeps through a long
  computation without polling.
  """
  @spec await(String.t(), non_neg_integer()) :: {:ok, entry()} | :timeout | :no_job
  def await(issue_id, timeout_ms) when is_binary(issue_id) do
    # A previous await that timed out may have left its completion message
    # behind; without this, the next await for the same issue would return that
    # stale result instead of waiting on the job actually running now.
    flush_finished(issue_id)

    case subscribe(issue_id) do
      {:running, _entry} ->
        receive do
          {:job_finished, ^issue_id, entry} -> {:ok, entry}
        after
          timeout_ms ->
            unsubscribe(issue_id)
            :timeout
        end

      {:finished, entry} ->
        {:ok, entry}

      :no_job ->
        :no_job
    end
  end

  @doc """
  Jobs currently running, bucketed by compute tier.
  """
  @spec running_by_compute() :: %{String.t() => non_neg_integer()}
  def running_by_compute do
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {_id, entry} -> entry.status == :running end)
    |> Enum.frequencies_by(fn {_id, entry} -> entry.compute end)
  end

  defp flush_finished(issue_id) do
    receive do
      {:job_finished, ^issue_id, _entry} -> flush_finished(issue_id)
    after
      0 -> :ok
    end
  end

  defp subscribe(issue_id) do
    if ready?(), do: GenServer.call(__MODULE__, {:subscribe, issue_id, self()}), else: :no_job
  end

  defp unsubscribe(issue_id) do
    if ready?(), do: GenServer.cast(__MODULE__, {:unsubscribe, issue_id, self()})
    :ok
  end

  defp ready?, do: :ets.whereis(@table) != :undefined

  # Every record comes back, not just the running ones: a finished job still
  # holds its result, and the slot stays occupied until the agent has read it.
  # Losing that on restart would lose the answer the computation produced.
  defp recover_record(path) do
    with true <- String.ends_with?(path, ".json"),
         {:ok, contents} <- File.read(path),
         {:ok, %{"issue_id" => issue_id} = record} <- Jason.decode(contents) do
      :ets.insert(@table, {issue_id, recovered_entry(record)})
    else
      _ -> :ok
    end
  end

  defp recovered_entry(%{"status" => "running"} = record) do
    Logger.warning("Job #{record["job_id"]} survived a restart and is no longer attached (os process still alive: #{os_process_alive?(record["os_pid"])})")

    entry(record, :orphaned)
  end

  defp recovered_entry(record), do: entry(record, String.to_existing_atom(record["status"] || "orphaned"))

  @doc """
  Whether an orphaned job's OS process is still running.

  Killing the BEAM does not kill the computation: the process is reparented and
  keeps going, we just lose the port. An agent picking the work back up needs
  to know which of the two happened before it decides to resubmit.
  """
  @spec os_process_alive?(integer() | nil) :: boolean()
  def os_process_alive?(os_pid) when is_integer(os_pid) do
    match?({_output, 0}, System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true))
  end

  def os_process_alive?(_os_pid), do: false

  defp entry(record, status) do
    %{
      job_id: record["job_id"],
      issue_id: record["issue_id"],
      identifier: record["identifier"],
      command: record["command"],
      label: record["label"],
      compute: record["compute"] || "light",
      status: status,
      started_at: parse_timestamp(record["started_at"]),
      finished_at: record["finished_at"] && parse_timestamp(record["finished_at"]),
      exit_status: record["exit_status"],
      log_file: record["log_file"],
      os_pid: record["os_pid"],
      runner: nil,
      last_line: nil
    }
  end

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_value), do: DateTime.utc_now()

  @impl true
  def handle_call({:claim, issue_id, attrs}, _from, state) do
    {:reply, do_claim(issue_id, attrs), state}
  end

  def handle_call({:finish, issue_id, status, exit_status}, _from, state) do
    case get(issue_id) do
      nil ->
        {:reply, :ok, state}

      entry ->
        finished = %{entry | status: status, exit_status: exit_status, finished_at: DateTime.utc_now(), runner: nil}
        :ets.insert(@table, {issue_id, finished})
        persist(finished)

        {subscribers, remaining} = Map.pop(state.subscribers, issue_id, [])
        Enum.each(subscribers, &send(&1, {:job_finished, issue_id, finished}))

        {:reply, :ok, %{state | subscribers: remaining}}
    end
  end

  def handle_call({:release, issue_id}, _from, state) do
    :ets.delete(@table, issue_id)
    File.rm(record_path(issue_id))
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, issue_id, pid}, _from, state) do
    case get(issue_id) do
      nil ->
        {:reply, :no_job, state}

      %{status: :running} = entry ->
        subscribers = Map.update(state.subscribers, issue_id, [pid], &[pid | &1])
        {:reply, {:running, entry}, %{state | subscribers: subscribers}}

      entry ->
        {:reply, {:finished, entry}, state}
    end
  end

  @impl true
  def handle_cast({:attach_os_pid, issue_id, os_pid}, state) do
    case get(issue_id) do
      nil -> :ok
      entry -> :ets.insert(@table, {issue_id, %{entry | os_pid: os_pid}})
    end

    {:noreply, state}
  end

  def handle_cast({:attach_runner, issue_id, runner}, state) do
    case get(issue_id) do
      nil -> :ok
      entry -> :ets.insert(@table, {issue_id, %{entry | runner: runner}})
    end

    {:noreply, state}
  end

  def handle_cast({:record_output, issue_id, line}, state) do
    case get(issue_id) do
      nil -> :ok
      entry -> :ets.insert(@table, {issue_id, %{entry | last_line: line}})
    end

    {:noreply, state}
  end

  def handle_cast({:unsubscribe, issue_id, pid}, state) do
    subscribers = Map.update(state.subscribers, issue_id, [], &List.delete(&1, pid))
    {:noreply, %{state | subscribers: subscribers}}
  end

  defp do_claim(issue_id, attrs) do
    compute = Map.get(attrs, :compute) || Config.settings!().jobs.default_compute

    case get(issue_id) do
      %{status: :running} = running ->
        {:error, {:already_running, running}}

      _ ->
        case compute_headroom(compute) do
          :ok -> insert_claim(issue_id, attrs, compute)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp insert_claim(issue_id, attrs, compute) do
    entry = %{
      job_id: "job-" <> (16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)),
      issue_id: issue_id,
      identifier: Map.get(attrs, :identifier),
      command: Map.fetch!(attrs, :command),
      label: Map.get(attrs, :label),
      compute: compute,
      status: :running,
      started_at: DateTime.utc_now(),
      finished_at: nil,
      exit_status: nil,
      log_file: Map.fetch!(attrs, :log_file),
      os_pid: nil,
      runner: Map.get(attrs, :runner),
      last_line: nil
    }

    :ets.insert(@table, {issue_id, entry})
    persist(entry)
    {:ok, entry}
  end

  # Agent sessions are limited per state, but a session is cheap and a job is
  # not, so CPU budget is enforced here rather than on the scheduler.
  defp compute_headroom(compute) do
    limits = Config.settings!().jobs.max_concurrent_by_compute
    normalized = compute |> to_string() |> String.downcase()

    case Map.get(limits, normalized) do
      limit when is_integer(limit) ->
        if Map.get(running_by_compute(), compute, 0) >= limit do
          {:error, {:compute_limit, compute, limit}}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  @doc """
  Absolute path of the on-disk record for `issue_id`.
  """
  @spec record_path(String.t()) :: Path.t()
  def record_path(issue_id) do
    Path.join(Config.settings!().jobs.root, "#{Base.url_encode64(issue_id, padding: false)}.json")
  end

  defp persist(entry) do
    path = record_path(entry.issue_id)

    payload =
      Jason.encode!(
        %{
          "job_id" => entry.job_id,
          "issue_id" => entry.issue_id,
          "identifier" => entry.identifier,
          "command" => entry.command,
          "label" => entry.label,
          "compute" => entry.compute,
          "status" => Atom.to_string(entry.status),
          "started_at" => DateTime.to_iso8601(entry.started_at),
          "finished_at" => entry.finished_at && DateTime.to_iso8601(entry.finished_at),
          "exit_status" => entry.exit_status,
          "log_file" => entry.log_file,
          "os_pid" => entry.os_pid
        },
        pretty: true
      )

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, payload) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Unable to record job at #{path}: #{inspect(reason)}")
        :ok
    end
  end
end
