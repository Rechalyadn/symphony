defmodule SymphonyElixir.ThreadStore do
  @moduledoc """
  Per-workspace record of the Codex thread an issue is bound to.

  The record lives inside the issue workspace, so it shares the workspace
  lifetime: when the workspace is removed the thread binding goes with it and
  the next run cold-starts. Only local workspaces are tracked; remote worker
  hosts always cold-start.
  """

  require Logger

  @relative_path Path.join(".symphony", "thread.json")

  @type record :: %{
          thread_id: String.t(),
          last_state: String.t() | nil,
          last_run_at: String.t() | nil
        }

  @doc """
  Absolute path of the record for `workspace`.
  """
  @spec path(Path.t()) :: Path.t()
  def path(workspace) when is_binary(workspace), do: Path.join(workspace, @relative_path)

  @doc """
  Reads the stored record, or `nil` when absent, unreadable, or malformed.

  A missing or corrupt record is not an error: it means this run cold-starts.
  """
  @spec load(Path.t(), String.t() | nil) :: record() | nil
  def load(workspace, worker_host \\ nil) do
    with true <- is_nil(worker_host) and is_binary(workspace),
         {:ok, contents} <- File.read(path(workspace)),
         {:ok, %{"thread_id" => thread_id} = decoded} when is_binary(thread_id) <-
           Jason.decode(contents) do
      %{
        thread_id: thread_id,
        last_state: Map.get(decoded, "last_state"),
        last_run_at: Map.get(decoded, "last_run_at")
      }
    else
      _ -> nil
    end
  end

  @doc """
  Records the thread an issue is bound to.

  Call this only once the thread has a completed turn: Codex writes the rollout
  file lazily, so a thread id captured before the first turn cannot be resumed.
  """
  @spec save(Path.t(), String.t(), String.t() | nil, String.t() | nil) :: :ok
  def save(workspace, thread_id, issue_state, worker_host \\ nil) do
    if is_nil(worker_host) and is_binary(workspace) and is_binary(thread_id) do
      write_record(path(workspace), thread_id, issue_state)
    end

    :ok
  end

  defp write_record(file, thread_id, issue_state) do
    payload =
      Jason.encode!(
        %{
          "thread_id" => thread_id,
          "last_state" => issue_state,
          "last_run_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        },
        pretty: true
      )

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, payload) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Unable to record Codex thread at #{file}: #{inspect(reason)}")
        :ok
    end
  end
end
