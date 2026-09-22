defmodule SymphonyElixir.Agent.Intents do
  @moduledoc """
  Holds the state change an agent has registered for the issue it is working on.

  The agent may not move a work item itself: the orchestrator kills a running
  agent within one poll cycle of the item leaving an active state, so a
  mid-turn transition throws away whatever the agent had not finished. The
  agent therefore only registers an intent here, and `SymphonyElixir.AgentRunner`
  applies it once the run has returned cleanly.

  Entries live in a public ETS table so the tool executor and the runner can be
  different processes. A run that crashes leaves its entry behind, so the
  runner clears the issue before each run rather than trusting the table to be
  empty.
  """

  use GenServer

  require Logger

  @table __MODULE__

  @type intent :: %{
          to_state: String.t(),
          reason: String.t() | nil,
          requested_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Registers the state this run should end in. A second call replaces the first.
  """
  @spec put(String.t(), String.t(), String.t() | nil) :: :ok
  def put(issue_id, to_state, reason) when is_binary(issue_id) and is_binary(to_state) do
    :ets.insert(@table, {issue_id, %{to_state: to_state, reason: reason, requested_at: DateTime.utc_now()}})
    :ok
  end

  @doc """
  Reads the registered intent without consuming it.
  """
  @spec peek(String.t()) :: intent() | nil
  def peek(issue_id) do
    if ready?() and is_binary(issue_id) do
      case :ets.lookup(@table, issue_id) do
        [{^issue_id, intent}] -> intent
        _ -> nil
      end
    end
  end

  @doc """
  Reads and removes the registered intent.
  """
  @spec take(String.t()) :: intent() | nil
  def take(issue_id) do
    intent = peek(issue_id)
    clear(issue_id)
    intent
  end

  @doc """
  Drops any intent left over from an earlier run of this issue.
  """
  @spec clear(String.t()) :: :ok
  def clear(issue_id) do
    if ready?() and is_binary(issue_id), do: :ets.delete(@table, issue_id)
    :ok
  end

  defp ready?, do: :ets.whereis(@table) != :undefined
end
