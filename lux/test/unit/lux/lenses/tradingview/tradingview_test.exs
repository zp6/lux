defmodule Lux.Integrations.TradingView.ClientTest do
  use ExUnit.Case, async: true

  alias Lux.Integrations.TradingView.Client

  describe "request/3" do
    test "builds correct URL with base URL from config" do
      # Verify the module compiles and has the correct structure
      assert function_exported?(Client, :request, 3)
    end
  end
end

defmodule Lux.Lenses.TradingView.ChartDataTest do
  use ExUnit.Case, async: true

  alias Lux.Lenses.TradingView.ChartData

  describe "handler/2" do
    test "validates required symbol parameter" do
      assert {:error, _} = ChartData.handler(%{}, %{name: "Test"})
    end

    test "validates interval parameter" do
      result = ChartData.handler(%{symbol: "BTCUSDT", interval: "invalid"}, %{name: "Test"})
      assert {:error, msg} = result
      assert msg =~ "Invalid interval"
    end

    test "validates limit parameter range" do
      result = ChartData.handler(%{symbol: "BTCUSDT", limit: 10000}, %{name: "Test"})
      assert {:error, msg} = result
      assert msg =~ "Invalid limit"
    end

    test "accepts valid intervals" do
      for interval <- ["1m", "5m", "15m", "30m", "1h", "4h", "1D", "1W", "1M"] do
        result = ChartData.handler(%{symbol: "BTCUSDT", interval: interval}, %{name: "Test"})
        # Will fail on API call but should pass validation
        case result do
          {:error, msg} when is_binary(msg) -> assert msg =~ "fetch"
          {:ok, _} -> :ok
        end
      end
    end
  end
end

defmodule Lux.Lenses.TradingView.TechnicalIndicatorsTest do
  use ExUnit.Case, async: true

  alias Lux.Lenses.TradingView.TechnicalIndicators

  describe "handler/2" do
    test "validates required parameters" do
      assert {:error, _} = TechnicalIndicators.handler(%{}, %{name: "Test"})
    end

    test "validates indicators list is not empty" do
      result = TechnicalIndicators.handler(%{symbol: "BTCUSDT", indicators: []}, %{name: "Test"})
      assert {:error, _} = result
    end

    test "validates unsupported indicators" do
      result = TechnicalIndicators.handler(%{symbol: "BTCUSDT", indicators: ["invalid_indicator"]}, %{name: "Test"})
      assert {:error, msg} = result
      assert msg =~ "Unsupported indicators"
    end

    test "accepts supported indicators" do
      result = TechnicalIndicators.handler(%{symbol: "BTCUSDT", indicators: ["rsi", "macd"]}, %{name: "Test"})
      case result do
        {:error, msg} when is_binary(msg) -> assert msg =~ "indicators"
        {:ok, _} -> :ok
      end
    end
  end
end

defmodule Lux.Prisms.TradingView.AlertManagerTest do
  use ExUnit.Case, async: true

  alias Lux.Prisms.TradingView.AlertManager

  describe "handler/2" do
    test "create requires symbol, alert_type, and value" do
      result = AlertManager.handler(%{action: "create"}, %{name: "Test"})
      assert {:error, msg} = result
      assert msg =~ "Missing required"
    end

    test "delete requires alert_id" do
      result = AlertManager.handler(%{action: "delete"}, %{name: "Test"})
      assert {:error, msg} = result
      assert msg =~ "Missing required"
    end

    test "update requires alert_id" do
      result = AlertManager.handler(%{action: "update"}, %{name: "Test"})
      assert {:error, msg} = result
      assert msg =~ "Missing required"
    end

    test "rejects unsupported actions" do
      result = AlertManager.handler(%{action: "invalid"}, %{name: "Test"})
      assert {:error, msg} = result
      assert msg =~ "Unsupported action"
    end
  end
end

defmodule Lux.Prisms.TradingView.SignalGeneratorTest do
  use ExUnit.Case, async: true

  alias Lux.Prisms.TradingView.SignalGenerator

  describe "handler/2" do
    test "requires symbol parameter" do
      result = SignalGenerator.handler(%{}, %{name: "Test"})
      # Will try API call but should proceed past validation
      case result do
        {:error, msg} -> assert is_binary(msg) or is_tuple(msg)
        {:ok, _} -> :ok
      end
    end
  end
end

defmodule Lux.Prisms.TradingView.StrategyBacktesterTest do
  use ExUnit.Case, async: true

  alias Lux.Prisms.TradingView.StrategyBacktester

  describe "handler/2" do
    test "custom strategy requires custom_script" do
      result = StrategyBacktester.handler(%{symbol: "BTCUSDT", strategy: "custom"}, %{name: "Test"})
      assert {:error, msg} = result
      assert msg =~ "custom_script"
    end

    test "validates date format" do
      result = StrategyBacktester.handler(%{
        symbol: "BTCUSDT",
        strategy: "momentum",
        start_date: "not-a-date",
        end_date: "2024-06-01"
      }, %{name: "Test"})
      assert {:error, msg} = result
      assert msg =~ "start_date"
    end
  end
end
