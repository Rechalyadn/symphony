defmodule SymphonyElixir.Jobs.Runner do
  @moduledoc """
  Owns the OS process of one long-running computation.

  It deliberately does not link to the agent runner task. An Erlang port dies
  with the process holding it, so a job started by the agent's own session
  would be killed the moment that session is restarted, stalled, or hits
  `agent.max_turns` — which is the whole reason jobs are hosted here instead.

  The heartbeat is a liveness signal, not a keepalive: each cycle checks the
  job process is actually alive before reporting, so a job that vanishes stops
  the heartbeat and lets the orchestrator's stall timer do its job.
  """

  use GenServer, restart: :temporary

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Jobs.Registry

  @type start_opts :: [
          issue_id: String.t(),
          identifier: String.t() | nil,
          command: String.t(),
          workspace: Path.t(),
          log_file: Path.t(),
          max_runtime_s: pos_integer(),
          recipient: pid() | nil
        ]

  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Kills the job's process tree and closes out its slot.
  """
  @spec cancel(pid(), String.t()) :: :ok
  def cancel(runner, reason) when is_pid(runner) do
    GenServer.cast(runner, {:cancel, reason})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    issue_id = Keyword.fetch!(opts, :issue_id)
    command = Keyword.fetch!(opts, :command)
    workspace = Keyword.fetch!(opts, :workspace)
    log_file = Keyword.fetch!(opts, :log_file)
    heartbeat_ms = Config.settings!().jobs.heartbeat_ms
    max_runtime_s = Keyword.fetch!(opts, :max_runtime_s)

    File.mkdir_p!(Path.dirname(log_file))

    port =
      Port.open(
        {:spawn_executable, System.find_executable("bash")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:line, 65_536},
          args: ["-lc", command],
          cd: String.to_charlist(workspace)
        ]
      )

    {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
    Registry.attach_os_pid(issue_id, os_pid)

    Process.send_after(self(), :heartbeat, heartbeat_ms)
    Process.send_after(self(), :max_runtime, max_runtime_s * 1_000)

    {:ok,
     %{
       port: port,
       issue_id: issue_id,
       identifier: Keyword.get(opts, :identifier),
       log_file: log_file,
       heartbeat_ms: heartbeat_ms,
       recipient: Keyword.get(opts, :recipient),
       started_at: System.monotonic_time(:second),
       last_line: nil
     }}
  end

  @impl true
  def handle_info({port, {:data, {_flag, line}}}, %{port: port} = state) do
    File.write(state.log_file, line <> "\n", [:append])
    Registry.record_output(state.issue_id, line)
    {:noreply, %{state | last_line: line}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("Job finished issue_id=#{state.issue_id} exit_status=#{status}")
    Registry.finish(state.issue_id, :exited, status)
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info(:heartbeat, state) do
    if port_alive?(state.port) do
      emit_progress(state)
      Process.send_after(self(), :heartbeat, state.heartbeat_ms)
      {:noreply, state}
    else
      # The heartbeat is a real signal. Staying quiet here is what lets the
      # orchestrator's stall timer notice a job that disappeared.
      {:noreply, state}
    end
  end

  def handle_info(:max_runtime, state) do
    Logger.warning("Job exceeded jobs.max_runtime_s issue_id=#{state.issue_id}; killing it")
    kill(state, :killed)
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    Registry.finish(state.issue_id, :orphaned, nil)
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast({:cancel, reason}, state) do
    Logger.info("Job cancelled issue_id=#{state.issue_id} reason=#{inspect(reason)}")
    kill(state, :killed)
    {:stop, :normal, %{state | port: nil}}
  end

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    close_port(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp kill(state, status) do
    close_port(state.port)
    Registry.finish(state.issue_id, status, nil)
  end

  defp close_port(port) when is_port(port) do
    # Kill the shell's whole process group: the computation is usually a child
    # of the bash we spawned, and closing the port alone leaves it running. The
    # port's process is its own group leader, so `-pid` names the group; the
    # `--` matters, without it `kill` parses `-pid` as an option and does
    # nothing.
    with {:os_pid, os_pid} <- :erlang.port_info(port, :os_pid) do
      System.cmd("kill", ["-TERM", "--", "-#{os_pid}"], stderr_to_stdout: true)
    end

    Port.close(port)
  catch
    _, _ -> :ok
  end

  defp port_alive?(port), do: :erlang.port_info(port) != :undefined

  # The event name must never be one the orchestrator reads as "needs a human":
  # `:turn_input_required` and `:approval_required` put the issue in the blocked
  # map, where nothing but a state change or a restart gets it out.
  defp emit_progress(%{recipient: recipient} = state) when is_pid(recipient) do
    entry = Registry.get(state.issue_id)

    send(
      recipient,
      {:codex_worker_update, state.issue_id,
       %{
         event: :job_progress,
         timestamp: DateTime.utc_now(),
         payload: %{
           job_id: entry && entry.job_id,
           label: entry && entry.label,
           elapsed_s: System.monotonic_time(:second) - state.started_at,
           log_tail: state.last_line
         }
       }}
    )

    :ok
  end

  defp emit_progress(_state), do: :ok
end
