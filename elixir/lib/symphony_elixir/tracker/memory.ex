defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Tracker.Issue

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec list_state_names(Issue.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_state_names(%Issue{}) do
    case Application.get_env(:symphony_elixir, :memory_tracker_states) do
      names when is_list(names) -> {:ok, names}
      _ -> {:error, {:unsupported_tracker_operation, :list_state_names}}
    end
  end

  @spec apply_state_change(Issue.t(), String.t()) :: :ok | {:error, term()}
  def apply_state_change(%Issue{id: issue_id}, state_name) when is_binary(state_name) do
    applied = Application.get_env(:symphony_elixir, :memory_tracker_state_changes, [])
    Application.put_env(:symphony_elixir, :memory_tracker_state_changes, applied ++ [{issue_id, state_name}])

    updated =
      Enum.map(configured_issues(), fn
        %Issue{id: ^issue_id} = issue -> %{issue | state: state_name}
        other -> other
      end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, updated)
    :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_tracker_settings), do: []

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
