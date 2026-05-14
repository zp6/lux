defmodule Lux.Prisms.Telegram.Analytics.GetStatsTest do
  use UnitAPICase, async: false

  alias Lux.Prisms.Telegram.Analytics.GetStats
  alias Lux.Integrations.Telegram.Analytics

  @agent_ctx %{name: "TestAgent"}

  setup do
    analytics_name = :"analytics_getstats_test_#{System.unique_integer([:positive])}"
    start_supervised!({Analytics, name: analytics_name})

    # Track some data
    Analytics.track(:messages, :sent, 10)
    Analytics.track(:commands, "/start", 5)
    Process.sleep(20)

    :ok
  end

  describe "handler/2" do
    test "gets stats for a single namespace" do
      assert {:ok, result} = GetStats.handler(%{namespace: "messages"}, @agent_ctx)
      assert result.namespace == "messages"
      assert Map.has_key?(result, :stats)
      assert result.stats.total >= 10
    end

    test "gets stats for all namespaces" do
      assert {:ok, result} = GetStats.handler(%{namespace: "all"}, @agent_ctx)
      assert result.namespace == "all"
      assert Map.has_key?(result.stats, :messages)
      assert Map.has_key?(result.stats, :users)
    end

    test "returns error for invalid namespace" do
      assert {:error, msg} = GetStats.handler(%{namespace: "invalid"}, @agent_ctx)
      assert msg =~ "Invalid namespace"
    end
  end

  describe "schema validation" do
    test "validates input schema" do
      prism = GetStats.view()
      assert prism.input_schema.required == ["namespace"]
      assert Map.has_key?(prism.input_schema.properties, :namespace)
    end

    test "validates output schema" do
      prism = GetStats.view()
      assert prism.output_schema.required == ["namespace", "stats"]
    end
  end
end
