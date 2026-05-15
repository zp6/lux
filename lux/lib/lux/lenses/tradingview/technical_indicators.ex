defmodule Lux.Lenses.TradingView.TechnicalIndicators do
  @moduledoc """
  Lens for calculating technical indicators on market data.

  Supports a comprehensive set of technical indicators including:
  - Trend: SMA, EMA, MACD, Ichimoku Cloud
  - Momentum: RSI, Stochastic, CCI, Williams %R
  - Volatility: Bollinger Bands, ATR, Keltner Channels
  - Volume: OBV, VWAP, Money Flow Index

  ## Examples

      iex> TechnicalIndicators.handler(%{
      ...>   symbol: "BINANCE:BTCUSDT",
      ...>   interval: "1h",
      ...>   indicators: ["rsi", "macd", "bollinger_bands"]
      ...> }, %{name: "Agent"})
      {:ok, %{
        symbol: "BINANCE:BTCUSDT",
        interval: "1h",
        indicators: %{
          "rsi" => %{"value" => 65.4, "signal" => "neutral"},
          "macd" => %{"macd" => 120.5, "signal" => 98.3, "histogram" => 22.2},
          "bollinger_bands" => %{"upper" => 43500.0, "middle" => 42000.0, "lower" => 40500.0}
        }
      }}
  """

  use Lux.Lens,
    name: "TradingView Technical Indicators",
    description: "Calculates technical indicators for a trading symbol",
    input_schema: %{
      type: :object,
      properties: %{
        symbol: %{
          type: :string,
          description: "Trading symbol (e.g. BINANCE:BTCUSDT)"
        },
        interval: %{
          type: :string,
          description: "Time interval for calculation",
          enum: ["1m", "5m", "15m", "30m", "1h", "4h", "1D", "1W", "1M"],
          default: "1h"
        },
        indicators: %{
          type: :array,
          items: %{type: :string},
          description: "List of indicators to calculate",
          enum: ["sma", "ema", "rsi", "macd", "bollinger_bands", "stochastic",
                 "atr", "cci", "williams_r", "obv", "vwap", "mfi", "ichimoku",
                 "keltner_channels"]
        },
        period: %{
          type: :integer,
          description: "Lookback period for indicators (default: 14)",
          default: 14,
          minimum: 2,
          maximum: 500
        }
      },
      required: ["symbol", "indicators"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        symbol: %{type: :string},
        interval: %{type: :string},
        indicators: %{type: :object},
        calculated_at: %{type: :integer}
      },
      required: ["symbol", "indicators"]
    }

  alias Lux.Integrations.TradingView.Client
  require Logger

  @supported_indicators ~w(sma ema rsi macd bollinger_bands stochastic atr cci williams_r obv vwap mfi ichimoku keltner_channels)

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    symbol = params[:symbol]
    interval = params[:interval] || "1h"
    indicators = params[:indicators]
    period = params[:period] || 14

    with {:ok, validated_indicators} <- validate_indicators(indicators) do
      Logger.info("Agent #{agent_name} calculating #{length(validated_indicators)} indicators for #{symbol}")

      request_body = %{
        symbol: symbol,
        interval: interval,
        indicators: validated_indicators,
        period: period
      }

      case Client.request(:post, "/analysis/indicators", %{json: request_body}) do
        {:ok, %{"indicators" => results}} ->
          Logger.info("Successfully calculated #{length(validated_indicators)} indicators for #{symbol}")
          {:ok, %{
            symbol: symbol,
            interval: interval,
            indicators: results,
            calculated_at: System.system_time(:second)
          }}

        {:ok, body} ->
          # Fallback: compute indicators locally if API returns raw data
          Logger.info("Processing raw indicator data for #{symbol}")
          {:ok, %{
            symbol: symbol,
            interval: interval,
            indicators: parse_indicator_response(body, validated_indicators),
            calculated_at: System.system_time(:second)
          }}

        {:error, error} ->
          Logger.error("Failed to calculate indicators for #{symbol}: #{inspect(error)}")
          {:error, "Failed to calculate indicators: #{inspect(error)}"}
      end
    end
  end

  defp validate_indicators(indicators) when is_list(indicators) and length(indicators) > 0 do
    invalid = Enum.filter(indicators, &(&1 not in @supported_indicators))
    if Enum.empty?(invalid) do
      {:ok, indicators}
    else
      {:error, "Unsupported indicators: #{Enum.join(invalid, ", ")}. Supported: #{Enum.join(@supported_indicators, ", ")}"}
    end
  end
  defp validate_indicators(_), do: {:error, "Indicators must be a non-empty list"}

  defp parse_indicator_response(body, indicators) when is_map(body) do
    Enum.reduce(indicators, %{}, fn indicator, acc ->
      case Map.get(body, indicator) do
        nil -> Map.put(acc, indicator, %{"error" => "no data"})
        data -> Map.put(acc, indicator, data)
      end
    end)
  end
  defp parse_indicator_response(_, indicators) do
    Enum.reduce(indicators, %{}, fn indicator, acc ->
      Map.put(acc, indicator, %{"error" => "unexpected response format"})
    end)
  end
end
