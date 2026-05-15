defmodule Lux.Prisms.Binance.Futures.CreateFuturesOrderPrism do
  @moduledoc """
  A prism for placing futures orders on Binance.

  Supports LIMIT, MARKET, STOP, TAKE_PROFIT, and STOP_MARKET order types
  with leverage and position management.

  ## Examples

      # Limit long order with leverage
      iex> Lux.Prisms.Binance.Futures.CreateFuturesOrderPrism.handler(%{
      ...>   symbol: "BTCUSDT",
      ...>   side: "BUY",
      ...>   type: "LIMIT",
      ...>   quantity: 0.001,
      ...>   price: "50000.00",
      ...>   time_in_force: "GTC",
      ...>   leverage: 10
      ...> }, %{})
      {:ok, %{symbol: "BTCUSDT", order_id: 12345, status: "NEW"}}
  """

  use Lux.Prism,
    name: "Binance Futures Create Order",
    description: "Places a new futures order on Binance with leverage control",
    input_schema: %{
      type: :object,
      properties: %{
        symbol: %{
          type: :string,
          description: "Trading pair symbol (e.g., 'BTCUSDT')"
        },
        side: %{
          type: :string,
          description: "Order side",
          enum: ["BUY", "SELL"]
        },
        position_side: %{
          type: :string,
          description: "Position side for hedge mode",
          enum: ["BOTH", "LONG", "SHORT"]
        },
        type: %{
          type: :string,
          description: "Order type",
          enum: ["LIMIT", "MARKET", "STOP", "TAKE_PROFIT", "STOP_MARKET", "TAKE_PROFIT_MARKET"]
        },
        quantity: %{
          type: :number,
          description: "Order quantity"
        },
        price: %{
          type: :string,
          description: "Order price (for LIMIT orders)"
        },
        stop_price: %{
          type: :string,
          description: "Trigger price for stop orders"
        },
        time_in_force: %{
          type: :string,
          description: "Time in force",
          enum: ["GTC", "IOC", "FOK", "GTD"]
        },
        reduce_only: %{
          type: :boolean,
          description: "Whether this order can only reduce position",
          default: false
        },
        close_position: %{
          type: :boolean,
          description: "Close all position with this order",
          default: false
        },
        leverage: %{
          type: :integer,
          description: "Leverage to set for this symbol (1-125)",
          minimum: 1,
          maximum: 125
        },
        activation_price: %{
          type: :string,
          description: "Trailing stop activation price"
        },
        callback_rate: %{
          type: :number,
          description: "Trailing stop callback rate (0.1-5)%"
        },
        working_type: %{
          type: :string,
          description: "Stop price trigger type",
          enum: ["MARK_PRICE", "CONTRACT_PRICE"]
        }
      },
      required: ["symbol", "side", "type"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        symbol: %{type: :string},
        order_id: %{type: :integer},
        status: %{type: :string},
        leverage_set: %{type: :boolean}
      },
      required: ["symbol", "order_id", "status"]
    }

  alias Lux.Integrations.Binance.Client
  require Logger

  def handler(params, _ctx) do
    symbol = Map.fetch!(params, :symbol)

    with {:ok, _} <- maybe_set_leverage(symbol, Map.get(params, :leverage)) do
      Logger.info("Placing Binance futures order: #{params[:side]} #{params[:type]} #{symbol}")

      request_params = build_futures_params(params)

      case Client.futures_request(:post, "/fapi/v1/order", %{signed: true, params: request_params}) do
        {:ok, result} ->
          {:ok, %{
            symbol: result["symbol"],
            order_id: result["orderId"],
            client_order_id: result["clientOrderId"],
            status: result["status"],
            executed_qty: result["executedQty"],
            orig_qty: result["origQty"],
            price: result["price"],
            type: result["type"],
            side: result["side"],
            reduce_only: result["reduceOnly"],
            leverage_set: Map.has_key?(params, :leverage),
            update_time: result["updateTime"]
          }}

        {:error, {:rate_limited, retry_after}} ->
          {:error, "Futures rate limited. Retry after #{retry_after}ms"}

        {:error, {status, %{"code" => code, "msg" => msg}}} ->
          {:error, "Binance Futures error (#{status}): [#{code}] #{msg}"}

        {:error, error} ->
          {:error, "Failed to place futures order: #{inspect(error)}"}
      end
    end
  end

  defp maybe_set_leverage(_symbol, nil), do: {:ok, :no_leverage_change}

  defp maybe_set_leverage(symbol, leverage) when is_integer(leverage) and leverage >= 1 and leverage <= 125 do
    Logger.info("Setting leverage for #{symbol} to #{leverage}x")

    case Client.futures_request(:post, "/fapi/v1/leverage", %{signed: true, params: %{symbol: symbol, leverage: leverage}}) do
      {:ok, %{"leverage" => ^leverage}} -> {:ok, :leverage_set}
      {:error, error} -> {:error, "Failed to set leverage: #{inspect(error)}"}
    end
  end

  defp maybe_set_leverage(_symbol, leverage), do: {:error, "Invalid leverage: #{leverage}"}

  defp build_futures_params(params) do
    params
    |> Map.take([:symbol, :side, :position_side, :type, :quantity, :price,
                 :stop_price, :time_in_force, :reduce_only, :close_position,
                 :activation_price, :callback_rate, :working_type])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {k, to_string(v)} end)
  end
end
