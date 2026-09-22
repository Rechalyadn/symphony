defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Agent.Intents
  alias SymphonyElixir.AgentTools
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, PromptBuilder, ThreadStore, Tracker, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host),
               :ok <- run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
            # Only a run that returned cleanly gets to move the work item:
            # unfinished work should not leave a state change behind.
            apply_requested_state_change(issue)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)
    stored_thread = stored_thread(workspace, worker_host)
    tool_names = AgentTools.tool_names(AgentTools.bind())

    # A run that crashed mid-turn can leave an intent behind. Clear it rather
    # than open this run with the previous one's conclusion already registered.
    Intents.clear(issue.id)

    session_opts = [
      worker_host: worker_host,
      resume_thread_id: stored_thread && stored_thread.thread_id,
      issue: issue
    ]

    with :ok <- check_thread_tool_set(stored_thread, tool_names, workspace),
         {:ok, session} <- AppServer.start_session(workspace, session_opts) do
      context = %{
        app_session: session,
        workspace: workspace,
        codex_update_recipient: codex_update_recipient,
        opts: opts,
        issue_state_fetcher: issue_state_fetcher,
        stored_thread: stored_thread,
        tool_names: tool_names,
        max_turns: max_turns
      }

      try do
        do_run_codex_turns(context, issue, 1)
      after
        AppServer.stop_session(session)
      end
    end
  end

  # Codex freezes the dynamic tool set when the thread opens, so a thread
  # started before a tool existed can never see it. Resuming anyway produces
  # the worst kind of failure: the agent runs, finds the tool missing, and
  # reports something confusing. Stop instead and say exactly what to delete.
  defp check_thread_tool_set(%{tool_names: recorded}, tool_names, workspace)
       when is_list(recorded) and recorded != tool_names do
    Logger.error(
      "Codex thread in #{workspace} was opened with a different tool set (#{Enum.join(recorded, ", ")}); it can never see #{Enum.join(tool_names -- recorded, ", ")}. Delete .symphony/thread.json in that workspace to cold-start with the current tools."
    )

    {:error, {:thread_tool_set_changed, recorded, tool_names}}
  end

  defp check_thread_tool_set(_stored_thread, _tool_names, _workspace), do: :ok

  defp stored_thread(workspace, worker_host) do
    if Config.settings!().codex.resume_threads do
      ThreadStore.load(workspace, worker_host)
    end
  end

  defp do_run_codex_turns(context, issue, turn_number) do
    %{
      app_session: app_session,
      workspace: workspace,
      codex_update_recipient: codex_update_recipient,
      issue_state_fetcher: issue_state_fetcher,
      max_turns: max_turns
    } = context

    prompt = build_turn_prompt(context, issue, turn_number)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue),
             codex_update_recipient: codex_update_recipient
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      # Refresh before recording, never after. The refresh is what supplies the
      # comment watermark, and by now the agent's own comment has landed, so it
      # falls under the watermark instead of being reported back to the agent
      # next time as somebody else's news.
      outcome = continue_with_issue?(issue, issue_state_fetcher)
      maybe_record_thread(context, workspace, recordable_issue(outcome, issue))

      continue_after_turn(context, outcome, turn_number, max_turns)
    end
  end

  defp recordable_issue({:continue, %Issue{} = refreshed_issue}, _issue), do: refreshed_issue
  defp recordable_issue({:done, %Issue{} = refreshed_issue}, _issue), do: refreshed_issue
  defp recordable_issue(_outcome, issue), do: issue

  # Registering a state change is the agent saying it is done, which is the
  # only "finished" signal Symphony has beyond the work item leaving an active
  # state. Without it the turn loop can only ask the tracker.
  defp continue_after_turn(context, outcome, turn_number, max_turns) do
    case outcome do
      {_status, %Issue{} = refreshed_issue} when turn_number >= max_turns ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} turn=#{turn_number}/#{max_turns}; returning control to orchestrator")

        :ok

      {:continue, %Issue{} = refreshed_issue} ->
        if requested_state_change(refreshed_issue) do
          Logger.info("Agent registered a state change for #{issue_context(refreshed_issue)}; ending the run after turn=#{turn_number}/#{max_turns}")

          :ok
        else
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(context, refreshed_issue, turn_number + 1)
        end

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp requested_state_change(%Issue{id: issue_id}) when is_binary(issue_id), do: Intents.peek(issue_id)
  defp requested_state_change(_issue), do: nil

  defp apply_requested_state_change(%Issue{id: issue_id} = issue) when is_binary(issue_id) do
    case Intents.take(issue_id) do
      nil ->
        :ok

      %{to_state: to_state, reason: reason} ->
        Logger.info("Applying requested state change for #{issue_context(issue)} to=#{to_state} reason=#{inspect(reason)}")

        apply_state_change(issue, to_state)
    end
  end

  defp apply_requested_state_change(_issue), do: :ok

  defp apply_state_change(issue, to_state) do
    case Tracker.apply_state_change(issue, to_state) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Unable to move #{issue_context(issue)} to #{to_state}: #{inspect(reason)}")
        {:error, {:state_change_failed, to_state, reason}}
    end
  end

  defp maybe_record_thread(context, workspace, %Issue{} = issue) do
    do_record_thread(context.app_session, workspace, issue, context.tool_names)
  end

  defp do_record_thread(%{resumed: _, thread_id: thread_id, worker_host: worker_host}, workspace, %Issue{} = issue, tool_names) do
    # Codex writes the rollout file lazily, so the thread only becomes
    # resumable once a turn has completed. Record it here, never earlier.
    if Config.settings!().codex.resume_threads do
      attrs = %{issue_state: issue.state, latest_comment_at: issue.latest_comment_at, tool_names: tool_names}
      ThreadStore.save(workspace, thread_id, attrs, worker_host)
    end

    :ok
  end

  defp build_turn_prompt(%{app_session: %{resumed: true}} = context, issue, 1) do
    PromptBuilder.build_resume_prompt(issue, context.stored_thread, context.opts)
  end

  defp build_turn_prompt(context, issue, 1) do
    PromptBuilder.build_prompt(issue, context.opts)
  end

  # The agent now has `request_state_change` to say it is finished, so this no
  # longer has to push it to keep going while the work item stays active.
  defp build_turn_prompt(%{max_turns: max_turns}, _issue, turn_number) do
    """
    Continuation turn ##{turn_number} of #{max_turns}. The work item is still active and your previous turn ended without registering a state change.

    Pick up where you stopped. Register a state change when you are done.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
