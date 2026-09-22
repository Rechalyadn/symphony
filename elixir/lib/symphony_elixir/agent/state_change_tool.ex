defmodule SymphonyElixir.Agent.StateChangeTool do
  @moduledoc """
  Symphony-native tool letting an agent register the state its run should end in.

  Registering is all it does. Moving the work item is the runner's job, because
  a transition applied mid-turn would have the orchestrator kill the very run
  that asked for it.
  """

  require Logger

  alias SymphonyElixir.Agent.Intents
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Issue

  @tool "request_state_change"
  @description """
  Register the lifecycle state this work item should move to when you stop.

  Call it as soon as you know where the work item belongs, then finish what you
  are doing: Symphony applies the change only after your run returns, so
  nothing you are still working on gets cut short. Calling it also tells
  Symphony that this run is finished, so it will not open another turn.

  This is the only way to move a work item. Do not change state through the
  tracker's own API.
  """
  @input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["to_state"],
    "properties" => %{
      "to_state" => %{
        "type" => "string",
        "description" => "Name of the lifecycle state to move to, spelled as the tracker spells it."
      },
      "reason" => %{
        "type" => ["string", "null"],
        "description" => "One line on why, for the run log. Say the substance in a work item comment instead."
      }
    }
  }

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "type" => "function",
        "name" => @tool,
        "description" => @description,
        "inputSchema" => @input_schema
      }
    ]
  end

  @spec tool_names() :: [String.t()]
  def tool_names, do: [@tool]

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) do
    case {tool, Keyword.get(opts, :issue)} do
      {@tool, %Issue{} = issue} -> register(issue, arguments)
      {@tool, _issue} -> failure("Symphony did not bind a work item to this session, so the state change has nowhere to go.")
      {other, _issue} -> failure("Unsupported dynamic tool: #{inspect(other)}.")
    end
  end

  defp register(%Issue{} = issue, arguments) do
    with {:ok, to_state, reason} <- normalize(arguments),
         :ok <- validate_state(issue, to_state) do
      record(issue, to_state, reason)
    else
      {:error, {:unknown_state, to_state, known}} ->
        failure("`#{to_state}` is not a state this work item can be in. Known states: #{Enum.join(known, ", ")}.")

      {:error, :missing_to_state} ->
        failure("`request_state_change` requires a non-empty `to_state` string.")

      {:error, :invalid_arguments} ->
        failure("`request_state_change` expects an object with `to_state` and an optional `reason`.")
    end
  end

  defp record(%Issue{id: issue_id, identifier: identifier, state: state}, to_state, reason) do
    :ok = Intents.put(issue_id, to_state, reason)
    Logger.info("Agent requested state change issue_identifier=#{identifier} from=#{state} to=#{to_state} reason=#{inspect(reason)}")

    success(%{
      "registered" => true,
      "from_state" => state,
      "to_state" => to_state,
      "appliedWhen" => "after this run returns"
    })
  end

  defp normalize(arguments) when is_map(arguments) do
    to_state = Map.get(arguments, "to_state") || Map.get(arguments, :to_state)
    reason = Map.get(arguments, "reason") || Map.get(arguments, :reason)

    case to_state do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: {:error, :missing_to_state}, else: {:ok, trimmed, normalize_reason(reason)}

      _ ->
        {:error, :missing_to_state}
    end
  end

  defp normalize(_arguments), do: {:error, :invalid_arguments}

  defp normalize_reason(reason) when is_binary(reason), do: String.trim(reason)
  defp normalize_reason(_reason), do: nil

  # A typo is worth catching here: the agent gets it back while it can still
  # act, instead of the run ending and the transition failing silently later.
  # An unreachable tracker is not worth blocking on, so listing failures pass.
  defp validate_state(issue, to_state) do
    case Tracker.list_state_names(issue) do
      {:ok, known} ->
        if Enum.any?(known, &(normalize_name(&1) == normalize_name(to_state))) do
          :ok
        else
          {:error, {:unknown_state, to_state, known}}
        end

      {:error, reason} ->
        Logger.warning("Unable to list tracker states while validating a requested state change: #{inspect(reason)}")
        :ok
    end
  end

  defp normalize_name(name) when is_binary(name), do: name |> String.trim() |> String.downcase()

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
