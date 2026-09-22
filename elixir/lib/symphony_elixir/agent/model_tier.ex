defmodule SymphonyElixir.Agent.ModelTier do
  @moduledoc """
  Resolves the model and reasoning effort for one work item from its labels.

  Labels name a tier, never a model id: `model: terra` rather than a specific
  version. The mapping from tier to id lives in `codex.model_tiers` in
  `WORKFLOW.md`, so a model version bump is a one-line config change and the
  work items keep their labels.

  A missing or unrecognised label is not a dispatch error. The run falls back
  to whatever `codex.command` already configures globally and says so in the
  log, because refusing to run a work item over a typo in a label is worse than
  running it on the default model.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @model_group "model"
  @reasoning_group "reasoning"

  @type selection :: %{model: String.t() | nil, effort: String.t() | nil}

  @doc """
  The model and effort overrides for `issue`, or nils to keep the global ones.
  """
  @spec resolve(Issue.t() | nil) :: selection()
  def resolve(%Issue{} = issue) do
    codex = Config.settings!().codex

    %{
      model: lookup(issue, @model_group, codex.model_tiers, "model"),
      effort: lookup(issue, @reasoning_group, codex.reasoning_efforts, "reasoning effort")
    }
  end

  def resolve(_issue), do: %{model: nil, effort: nil}

  defp lookup(issue, group, mapping, label_for_log) when map_size(mapping) > 0 do
    case tier_label(issue, group, mapping) do
      {:ok, tier, value} ->
        Logger.info("Selected #{label_for_log} for #{issue.identifier} from label #{group}=#{tier}: #{value}")
        value

      {:error, tier} ->
        Logger.info("Unknown #{label_for_log} tier #{inspect(tier)} on #{issue.identifier}; keeping the globally configured one")
        nil

      :none ->
        nil
    end
  end

  defp lookup(_issue, _group, _mapping, _label_for_log), do: nil

  # Linear label groups come back as both the bare child name and
  # `group/child`, so either spelling works: a `model` group holding `terra`,
  # or a flat label named `model: terra`.
  defp tier_label(%Issue{labels: labels}, group, mapping) when is_list(labels) do
    prefixes = ["#{group}/", "#{group}:", "#{group}: "]

    labels
    |> Enum.map(&strip_prefix(&1, prefixes))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while(:none, fn tier, _acc ->
      case Map.fetch(mapping, tier) do
        {:ok, value} -> {:halt, {:ok, tier, value}}
        :error -> {:cont, {:error, tier}}
      end
    end)
  end

  defp tier_label(_issue, _group, _mapping), do: :none

  defp strip_prefix(label, prefixes) when is_binary(label) do
    normalized = label |> String.trim() |> String.downcase()

    Enum.find_value(prefixes, fn prefix ->
      case String.split(normalized, prefix, parts: 2) do
        ["", tier] -> String.trim(tier)
        _ -> nil
      end
    end)
  end

  defp strip_prefix(_label, _prefixes), do: nil
end
