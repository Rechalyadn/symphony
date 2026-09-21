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

  @default_resume_prompt """
  You are resuming an existing Codex thread for tracker work item {{ issue.identifier }}.
  Your prior context is still loaded, so do not restate the task or re-read what you already know.

  {% if previous_state %}The work item moved from `{{ previous_state }}` to `{{ issue.state }}` since your last turn.{% else %}The work item is now in `{{ issue.state }}`.{% endif %}
  {% if last_run_at %}Your last turn ended at {{ last_run_at }}; fetch the work item's comments and read anything added after that time.{% else %}Fetch the work item's comments and read anything you have not seen.{% endif %}

  Re-read the tracking workpad before acting, then continue from the current state.
  """

  @doc """
  Builds the first-turn prompt for a resumed thread.

  A resumed thread already holds the workflow prompt and the prior turns, so
  this injects only what changed while the agent was not running.
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
        "last_run_at" => stored_thread && stored_thread[:last_run_at]
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

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
