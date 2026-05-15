defmodule Lux.Prisms.TradingView.SignalGenerator do
  @moduledoc """
  Prism for generating trading signals based on technical analysis.

  Combines multiple indicators and chart patterns to produce actionable
  buy/sell/hold signals with confidence scores and risk assessment.

  ## Signal Types

  - `buy` - Bullish signal, recommend entering long position
  - `sell` - Bearish signal, recommend entering short position or closing long
  - `hold` - No clear directional bias, maintain current position
  - `strong_buy` - Multiple confluent bullish signals
  - `strong_sell` - Multiple confluent bearish signals

  ## Examples

      iex> SignalGenerator.handler(%{
      ...>   symbol: "BINANCE:BTCUSDT",
      ...>   interval: "1h",
      ...>   strategy: "momentum"
      ...> }, %{name: "Agent"})
      {:ok, %{
        symbol: "BINANCE:BTCUSDT",
        signal: "buy",
        confidence: 0.82,
        strategy: "momentum",
        indicators_used: ["rsi", "macd", "ema_20", "volume"],
        reasoning: "RSI at 65 with MACD bullish crossover, price above EMA20"
      }}
  """

  use Lux.Prism,
    name: "TradingView Signal Generator",
    description: "Generates buy/sell/hold signals based on technical analysis",
    input_schema: %{
      type: :object,
      properties: %{
        symbol: %{
          type: :string,
          description: "Trading symbol"
        },
        interval: %{
          type: :string,
          description: "Analysis timeframe",
          default: "1h"
        },
        strategy: %{
          type: :string,
          description: "Trading strategy to apply",
          enum: ["momentum", "mean_reversion", "trend_following", "breakout", "composite"],
          default: "composite"
        },
        risk_tolerance: %{
          type: :string,
          description: "Risk tolerance level",
          enum: ["conservative", "moderate", "aggressive"],
          default: "moderate"
        },
        indicators: %{
          type: :array,
          items: %{type: :string},
          description: "Custom indicator set (defaults based on strategy)"
        },
        min_confidence: %{
          type: :number,
          description: "Minimum confidence threshold (0.0-1.0)",
          default: 0.6,
          minimum: 0.0,
          maximum: 1.0
        }
      },
      required: ["symbol"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        symbol: %{type: :string},
        signal: %{type: :string, enum: ["strong_buy", "buy", "hold", "sell", "strong_sell"]},
        confidence: %{type: :number},
        strategy: %{type: :string},
        indicators_used: %{type: :array, items: %{type: :string}},
        reasoning: %{type: :string},
        risk_level: %{type: :string},
        generated_at: %{type: :integer}
      },
      required: ["symbol", "signal", "confidence", "strategy"]
    }

  alias Lux.Integrations.TradingView.Client
  require Logger

  @strategies %{
    "momentum" => ["rsi", "macd", "stochastic", "cci"],
    "mean_reversion" => ["bollinger_bands", "rsi", "williams_r"],
    "trend_following" => ["ema", "sma", "ichimoku", "atr"],
    "breakout" => ["bollinger_bands", "atr", "volume", "keltner_channels"],
    "composite" => ["rsi", "macd", "ema", "bollinger_bands", "atr", "volume"]
  }

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    symbol = params[:symbol]
    interval = params[:interval] || "1h"
    strategy = params[:strategy] || "composite"
    indicators = params[:indicators] || Map.get(@strategies, strategy, @strategies["composite"])

    Logger.info("Agent #{agent_name} generating #{strategy} signal for #{symbol}")

    request_body = %{
      symbol: symbol,
      interval: interval,
      strategy: strategy,
      indicators: indicators,
      risk_tolerance: params[:risk_tolerance] || "moderate",
      min_confidence: params[:min_confidence] || 0.6
    }

    case Client.request(:post, "/signals/generate", %{json: request_body}) do
      {:ok, %{"signal" => signal, "confidence" => confidence} = body} ->
        Logger.info("Signal for #{symbol}: #{signal} (confidence: #{confidence})")
        {:ok, %{
          symbol: symbol,
          signal: signal,
          confidence: confidence,
          strategy: strategy,
          indicators_used: indicators,
          reasoning: Map.get(body, "reasoning", ""),
          risk_level: Map.get(body, "risk_level", assess_risk(confidence)),
          generated_at: System.system_time(:second)
        }}

      {:ok, body} ->
        {:ok, %{
          symbol: symbol,
          signal: Map.get(body, "signal", "hold"),
          confidence: Map.get(body, "confidence", 0.0),
          strategy: strategy,
          indicators_used: indicators,
          reasoning: Map.get(body, "reasoning", "Raw API response"),
          risk_level: "moderate",
          generated_at: System.system_time(:second)
        }}

      {:error, error} ->
        Logger.error("Signal generation failed for #{symbol}: #{inspect(error)}")
        {:error, "Signal generation failed: #{inspect(error)}"}
    end
  end

  defp assess_risk(confidence) when confidence >= 0.8, do: "low"
  defp assess_risk(confidence) when confidence >= 0.6, do: "moderate"
  defp assess_risk(_), do: "high"
end
