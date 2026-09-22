defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Dispatches client-side tool calls to the tools bound for the session.
  """

  alias SymphonyElixir.AgentTools

  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(tool, arguments, binding, opts \\ []) do
    AgentTools.execute(binding, tool, arguments, opts)
  end

  @spec bind() :: map()
  def bind do
    AgentTools.bind()
  end
end
