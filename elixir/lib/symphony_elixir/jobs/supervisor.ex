defmodule SymphonyElixir.Jobs.Supervisor do
  @moduledoc """
  Supervises job processes, outside the agent runtime on purpose.

  `SymphonyElixir.AgentRuntimeSupervisor` restarts `:one_for_all`, so hanging
  jobs off it would kill every running computation whenever the orchestrator
  restarts. Jobs are its sibling instead, started before it so a job outlives
  the session that asked for it.
  """

  use DynamicSupervisor

  alias SymphonyElixir.Jobs.Runner

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_job(Runner.start_opts()) :: DynamicSupervisor.on_start_child()
  def start_job(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Runner, opts})
  end
end
