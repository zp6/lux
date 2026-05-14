defmodule Lux.Prisms.Telegram.Analytics.GenerateReportTest do
  use UnitAPICase, async: false

  alias Lux.Prisms.Telegram.Analytics.GenerateReport
  alias Lux.Integrations.Telegram.Analytics

  @agent_ctx %{name: "TestAgent"}

  setup do
    analytics_name = :"analytics_genreport_test_#{System.unique_integer([:positive])}"
    start_supervised!({Analytics, name: analytics_name})

    # Seed some data
    Analytics.track(:messages, :sent, 5)
    Analytics.track(:commands, "/start", 2)
    Analytics.record_response_time(120)
    Analytics.record_error("test_error", %{})
    Analytics.record_user_event(42, :started)
    Process.sleep(20)

    :ok
  end

  describe "handler/2" do
    test "generates a daily report" do
      assert {:ok, result} = GenerateReport.handler(%{window: "day"}, @agent_ctx)

      assert Map.has_key?(result, :report)
      report = result.report
      assert report.window == :day
      assert Map.has_key?(report, :summary)
      assert Map.has_key?(report, :messages)
      assert Map.has_key?(report, :users)
      assert Map.has_key?(report, :commands)
      assert Map.has_key?(report, :errors)
      assert Map.has_key?(report, :performance)
      assert Map.has_key?(report, :usage_patterns)
    end

    test "generates reports for all window sizes" do
      for window <- ["hour", "day", "week", "all"] do
        assert {:ok, result} = GenerateReport.handler(%{window: window}, @agent_ctx)
        assert result.report.window == String.to_existing_atom(window)
      end
    end

    test "uses day as default window" do
      assert {:ok, result} = GenerateReport.handler(%{}, @agent_ctx)
      assert result.report.window == :day
    end

    test "returns error for invalid window" do
      assert {:error, msg} = GenerateReport.handler(%{window: "invalid"}, @agent_ctx)
      assert msg =~ "Invalid window"
    end
  end

  describe "schema validation" do
    test "validates input schema" do
      prism = GenerateReport.view()
      # window is optional
      refute :window in (prism.input_schema.required || [])
      assert Map.has_key?(prism.input_schema.properties, :window)
    end

    test "validates output schema" do
      prism = GenerateReport.view()
      assert "report" in prism.output_schema.required
    end
  end
end
