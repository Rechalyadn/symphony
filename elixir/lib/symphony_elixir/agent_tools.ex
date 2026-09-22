defmodule SymphonyElixir.AgentTools do
  @moduledoc """
  The set of dynamic tools a Codex session is given.

  Two kinds are merged here: the tracker adapter's provider-native tools, which
  differ per tracker, and Symphony's own tools, which do not. Both are declared
  once per session in `thread/start` (or `thread/resume`) and dispatched by
  name, so this module owns both halves of that pairing.
  """

  alias SymphonyElixir.Agent.StateChangeTool
  alias SymphonyElixir.Jobs
  alias SymphonyElixir.Tracker

  @native_modules [StateChangeTool, Jobs.AgentTool]

  @type binding :: map()

  @doc """
  Captures the tools for one app-server session.

  Extends the tracker binding rather than replacing it, so tool advertisement
  and execution cannot drift across a workflow reload.
  """
  @spec bind() :: binding()
  def bind do
    tracker_binding = Tracker.bind_agent_tools()

    native_tools =
      @native_modules
      |> Enum.flat_map(fn module -> Enum.map(module.tool_names(), &{&1, module}) end)
      |> Map.new()

    tracker_binding
    |> Map.put(:tool_specs, tracker_binding.tool_specs ++ Enum.flat_map(@native_modules, & &1.tool_specs()))
    |> Map.put(:native_tools, native_tools)
  end

  @doc """
  The names a binding advertises, sorted.

  Recorded alongside a thread so a later run can tell that the tool set has
  changed since the thread was opened. Codex freezes `dynamicTools` at
  `thread/start`, so a resumed thread keeps the tools it was born with no
  matter what the next resume declares.
  """
  @spec tool_names(binding()) :: [String.t()]
  def tool_names(binding) do
    binding
    |> Map.get(:tool_specs, [])
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
    |> Enum.sort()
  end

  @doc """
  Runs one dynamic tool call against the tools captured by `bind/0`.
  """
  @spec execute(binding(), String.t() | nil, term(), keyword()) :: map()
  def execute(binding, tool, arguments, opts) do
    case Map.get(native_tools(binding), tool) do
      nil -> Tracker.execute_bound_agent_tool(binding, tool, arguments, opts)
      module -> module.execute(tool, arguments, opts)
    end
  end

  defp native_tools(binding), do: Map.get(binding, :native_tools, %{})
end
