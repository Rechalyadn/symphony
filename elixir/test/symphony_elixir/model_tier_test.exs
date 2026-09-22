defmodule SymphonyElixir.ModelTierTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.ModelTier
  alias SymphonyElixir.Linear.Client

  defp issue(labels) do
    %Issue{id: "issue-1", identifier: "GEN-11", title: "Backtest", state: "Scoped", labels: labels}
  end

  defp configure_tiers! do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_model_tiers: %{"terra" => "gpt-5.6-terra", "luna" => "gpt-5.6-luna"},
      codex_reasoning_efforts: %{"low" => "low", "deep" => "xhigh"}
    )
  end

  test "an unlabelled work item keeps the globally configured model" do
    configure_tiers!()

    assert %{model: nil, effort: nil} = ModelTier.resolve(issue([]))
  end

  test "resolves a tier written as a Linear label group" do
    configure_tiers!()

    assert %{model: "gpt-5.6-terra", effort: "xhigh"} =
             ModelTier.resolve(issue(["symphony", "model/terra", "reasoning/deep"]))
  end

  test "resolves a tier written as a flat prefixed label" do
    configure_tiers!()

    assert %{model: "gpt-5.6-luna"} = ModelTier.resolve(issue(["model: luna"]))
  end

  test "an unknown tier falls back rather than refusing to dispatch" do
    configure_tiers!()

    assert %{model: nil, effort: nil} = ModelTier.resolve(issue(["model/sol"]))
  end

  test "no mapping configured means no override" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert %{model: nil, effort: nil} = ModelTier.resolve(issue(["model/terra"]))
  end

  test "a bare label without the group prefix is not a tier" do
    # `low` alone is ambiguous: it could be a priority, a compute size, or
    # anything else somebody labelled the work item with.
    configure_tiers!()

    assert %{effort: nil} = ModelTier.resolve(issue(["low"]))
  end

  test "grouped Linear labels arrive as both the bare and qualified name" do
    normalized =
      Client.normalize_issue_for_test(%{
        "id" => "issue-1",
        "identifier" => "GEN-11",
        "title" => "Backtest",
        "state" => %{"name" => "Scoped"},
        "labels" => %{
          "nodes" => [
            %{"name" => "Terra", "parent" => %{"name" => "Model"}},
            %{"name" => "symphony", "parent" => nil}
          ]
        }
      })

    assert normalized.labels == ["terra", "model/terra", "symphony"]
  end
end
