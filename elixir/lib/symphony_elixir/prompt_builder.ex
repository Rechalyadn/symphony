defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from normalized tracker work item data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Tracker.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  # A resumed thread already holds the workflow prompt and every prior turn, so
  # the only thing worth injecting is what changed while the agent was not
  # running. Three deliberate omissions:
  #
  #   * no talk of whether the agent still has its context. Resuming worked, so
  #     it does; saying so only invites the agent to reason about its own memory.
  #   * no transition narrative. "Moved from X to Y" implies something just
  #     happened and sends the agent looking for it, and it has nothing to say
  #     when nothing moved. A state declaration is true either way.
  #   * no tool list. A closed list reads as exhaustive, and the agent concludes
  #     it has lost the shell, file and test abilities that were never listed.
  #     Tool usage belongs in the workflow prompt, which the thread still holds.
  #
  # Override with `codex.resume_prompt` to add workflow specifics.
  @default_resume_prompt """
  当前 Issue 生命周期状态被设置为：{{ issue.state }}
  {% if jobs_allowed %}本状态允许提交长时作业。
  {% endif %}{% if has_new_comments %}Issue 有新评论，请通过 linear_graphql 读取后再继续。
  {% endif %}
  """

  @doc """
  Builds the first-turn prompt for a resumed thread.
  """
  @spec build_resume_prompt(SymphonyElixir.Tracker.Issue.t(), map() | nil, keyword()) ::
          String.t()
  def build_resume_prompt(issue, stored_thread, opts \\ []) do
    resume_template!()
    |> parse_template!()
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map(),
        "previous_state" => stored_thread && stored_thread[:last_state],
        "last_run_at" => stored_thread && stored_thread[:last_run_at],
        "has_new_comments" => new_comments?(issue, stored_thread),
        "jobs_allowed" => jobs_allowed?(issue)
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
    |> String.trim()
    |> Kernel.<>("\n")
  end

  # The watermark was written after the previous turn finished, by which time
  # the agent's own comment had landed, so anything above it came from someone
  # else. Without a watermark we cannot tell, and a needless read costs less
  # than missing the feedback the agent was waiting for.
  defp new_comments?(%{latest_comment_at: nil}, _stored_thread), do: false

  defp new_comments?(%{latest_comment_at: latest}, stored_thread) do
    case stored_thread && stored_thread[:last_comment_at] do
      watermark when is_binary(watermark) ->
        case DateTime.from_iso8601(watermark) do
          {:ok, parsed, _offset} -> DateTime.compare(latest, parsed) == :gt
          _ -> true
        end

      _ ->
        true
    end
  end

  defp jobs_allowed?(%{state: state}) when is_binary(state) do
    Config.settings!().jobs.gated_states
    |> Enum.any?(&(normalize_state(&1) == normalize_state(state)))
  end

  defp jobs_allowed?(_issue), do: false

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()

  defp resume_template! do
    case Config.settings!().codex.resume_prompt do
      prompt when is_binary(prompt) ->
        if String.trim(prompt) == "", do: @default_resume_prompt, else: prompt

      _ ->
        @default_resume_prompt
    end
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
