defmodule Lux.Prisms.TradingView.StrategyBacktester do
  @moduledoc """
  Prism for backtesting trading strategies against historical data.

  Runs a strategy simulation over historical candle data and returns
  performance metrics including total return, Sharpe ratio, max drawdown,
  win rate, and trade history.

  ## Examples

      iex> StrategyBacktester.handler(%{
      ...>   symbol: "BINANCE:BTCUSDT",
      ...>   strategy: "momentum",
      ...>   interval: "1h",
      ...>   start_date: "2024-01-01",
      ...>   end_date: "2024-06-01",
      ...>   initial_capital: 10000.0
      ...> }, %{name: "Agent"})
      {:ok, %{
        symbol: "BINANCE:BTCUSDT",
        strategy: "momentum",
        total_return: 0.234,
        sharpe_ratio: 1.85,
        max_drawdown: -0.12,
        win_rate: 0.62,
        total_trades: 47,
        initial_capital: 10000.0,
        final_capital: 12340.0
      }}
  """

  use Lux.Prism,
    name: "TradingView Strategy Backtester",
    description: "Backtests a trading strategy against historical data",
    input_schema: %{
      type: :object,
      properties: %{
        symbol: %{
          type: :string,
          description: "Trading symbol to backtest"
        },
        strategy: %{
          type: :string,
          description: "Strategy name or Pine Script code",
          enum: ["momentum", "mean_reversion", "trend_following", "breakout", "custom"]
        },
        custom_script: %{
          type: :string,
          description: "Custom Pine Script strategy code (when strategy is 'custom')"
        },
        interval: %{
          type: :string,
          description: "Candle interval for backtesting",
          default: "1h"
        },
        start_date: %{
          type: :string,
          description: "Start date for backtest (YYYY-MM-DD)"
        },
        end_date: %{
          type: :string,
          description: "End date for backtest (YYYY-MM-DD)"
        },
        initial_capital: %{
          type: :number,
          description: "Starting capital amount",
          default: 10000.0,
          minimum: 100.0
        },
        position_size: %{
          type: :number,
          description: "Position size as fraction of capital (0.0-1.0)",
          default: 0.1,
          minimum: 0.01,
          maximum: 1.0
        },
        commission: %{
          type: :number,
          description: "Commission per trade as fraction (e.g. 0.001 for 0.1%)",
          default: 0.001,
          minimum: 0.0,
          maximum: 0.1
        },
        indicators: %{
          type: :array,
          items: %{type: :string},
          description: "Indicators to use with the strategy"
        }
      },
      required: ["symbol", "strategy"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        symbol: %{type: :string},
        strategy: %{type: :string},
        total_return: %{type: :number},
        sharpe_ratio: %{type: :number},
        max_drawdown: %{type: :number},
        win_rate: %{type: :number},
        total_trades: %{type: :integer},
        initial_capital: %{type: :number},
        final_capital: %{type: :number},
        trade_history: %{type: :array},
        metrics: %{type: :object}
      },
      required: ["symbol", "strategy", "total_return", "sharpe_ratio", "total_trades"]
    }

  alias Lux.Integrations.TradingView.Client
  require Logger

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    symbol = params[:symbol]
    strategy = params[:strategy]

    with :ok <- validate_dates(params),
         :ok <- validate_custom_script(params) do

      Logger.info("Agent #{agent_name} backtesting #{strategy} strategy for #{symbol}")

      body = build_backtest_body(params)

      case Client.request(:post, "/backtest/run", %{json: body}) do
        {:ok, results} ->
          Logger.info("Backtest complete for #{symbol}: return=#{Map.get(results, "total_return", "N/A")}")
          {:ok, format_backtest_results(symbol, strategy, params, results)}

        {:error, error} ->
          Logger.error("Backtest failed for #{symbol}: #{inspect(error)}")
          {:error, "Backtest failed: #{inspect(error)}"}
      end
    end
  end

  defp validate_dates(params) do
    with {:ok, start_str} <- get_optional_param(params, :start_date),
         {:ok, end_str} <- get_optional_param(params, :end_date) do
      case Date.from_iso8601(start_str) do
        {:error, _} -> {:error, "Invalid start_date format. Use YYYY-MM-DD"}
        _ ->
          case Date.from_iso8601(end_str) do
            {:error, _} -> {:error, "Invalid end_date format. Use YYYY-MM-DD"}
            _ -> :ok
          end
      end
    end
  end
  defp validate_dates(_), do: :ok

  defp validate_custom_script(%{strategy: "custom"} = params) do
    case Map.get(params, :custom_script) do
      script when is_binary(script) and byte_size(script) > 0 -> :ok
      _ -> {:error, "custom_script is required when strategy is 'custom'"}
    end
  end
  defp validate_custom_script(_), do: :ok

  defp get_optional_param(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      value -> {:ok, value}
    end
  end

  defp build_backtest_body(params) do
    base = %{
      symbol: params[:symbol],
      strategy: params[:strategy],
      interval: params[:interval] || "1h",
      initial_capital: params[:initial_capital] || 10000.0,
      position_size: params[:position_size] || 0.1,
      commission: params[:commission] || 0.001
    }

    params
    |> Map.take([:start_date, :end_date, :custom_script, :indicators])
    |> Map.merge(base)
  end

  defp format_backtest_results(symbol, strategy, params, results) do
    initial_capital = params[:initial_capital] || 10000.0
    total_return = Map.get(results, "total_return", 0.0)
    final_capital = Map.get(results, "final_capital", initial_capital * (1 + total_return))

    %{
      symbol: symbol,
      strategy: strategy,
      total_return: total_return,
      sharpe_ratio: Map.get(results, "sharpe_ratio", 0.0),
      max_drawdown: Map.get(results, "max_drawdown", 0.0),
      win_rate: Map.get(results, "win_rate", 0.0),
      total_trades: Map.get(results, "total_trades", 0),
      initial_capital: initial_capital,
      final_capital: final_capital,
      trade_history: Map.get(results, "trades", []),
      metrics: Map.get(results, "metrics", %{})
    }
  end
end
