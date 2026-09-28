import Config

# Service deployments (the `symphony_service` release) have no CLI to pass
# the workflow path and logs root, so they come from the environment. The
# escript reads its CLI flags instead and never evaluates this file.
if config_env() != :test do
  if workflow = System.get_env("SYMPHONY_WORKFLOW") do
    config :symphony_elixir, workflow_file_path: Path.expand(workflow)
  end

  if logs_root = System.get_env("SYMPHONY_LOGS_ROOT") do
    config :symphony_elixir, log_file: Path.join([Path.expand(logs_root), "log", "symphony.log"])
  end
end
