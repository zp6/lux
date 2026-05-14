defmodule Lux.Prisms.Telegram.Analytics.TrackMetricTest do
  use UnitAPICase, async: false

  alias Lux.Prisms.Telegram.Analytics.TrackMetric
  alias Lux.Integrations.Telegram.Analytics

  @agent_ctx %{name: "TestAgent"}

  setup do
    analytics_name = :"analytics_trackmetric_test_#{System.unique_integer([:positive])}"
    start_supervised!({Analytics, name: analytics_name})
    :ok
  end

  describe "handler/2" do
    test "tracks a counter metric" do
      assert {:ok, result} = TrackMetric.handler(%{
        namespace: "custom",
        key: "webhook_events",
        value: 1,
        type: "counter"
      }, @agent_ctx)

      assert result.tracked == true
      assert result.namespace == "custom"
      assert result.key == "webhook_events"
    end

    test "tracks a gauge metric" do
      assert {:ok, result} = TrackMetric.handler(%{
        namespace: "custom",
        key: "queue_size",
        value: 42,
        type: "gauge"
      }, @agent_ctx)

      assert result.tracked == true
      assert result.namespace == "custom"
    end

    test "uses default value of 1" do
      assert {:ok, result} = TrackMetric.handler(%{
        namespace: "messages",
        key: "received"
      }, @agent_ctx)

      assert result.tracked == true
    end

    test "returns error for invalid namespace" do
      assert {:error, msg} = TrackMetric.handler(%{
        namespace: "nonexistent",
        key: "test"
      }, @agent_ctx)

      assert msg =~ "Invalid namespace"
    end
  end

  describe "schema validation" do
    test "validates input schema" do
      prism = TrackMetric.view()
      assert "namespace" in prism.input_schema.required
      assert "key" in prism.input_schema.required
    end

    test "validates output schema" do
      prism = TrackMetric.view()
      assert "tracked" in prism.output_schema.required
      assert "namespace" in prism.output_schema.required
      assert "key" in prism.output_schema.required
    end
  end
end
