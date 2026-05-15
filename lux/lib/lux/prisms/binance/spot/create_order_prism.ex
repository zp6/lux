defmodule Lux.Prisms.Binance.Spot.CreateOrderPrism do
  @moduledoc """
  A prism for placing spot orders on Binance.

  Supports LIMIT, MARKET, STOP_LOSS, STOP_LOSS_LIMIT, TAKE_PROFIT, and TAKE_PROFIT_LIMIT orders.

  ## Examples

      # Market buy order
      iex> Lux.Prisms.Binance.Spot.CreateOrderPrism.handler(%{
      ...>   symbol: "BTCUSDT",
      ...>   side: "BUY",
      ...>   type: "MARKET",
      ...>   quantity: 0.001
      ...> }, %{})
      {:ok, %{symbol: "BTCUSDT", order_id: 12345, status: "FILLED", ...}}

      # Limit sell order
      iex> Lux.Prisms.Binance.Spot.CreateOrderPrism.handler(%{
      ...>   symbol: "ETHUSDT",
      ...>   side: "SELL",
      ...>   type: "LIMIT",
      ...>   quantity: 0.5,
      ...>   price: "3000.00",
      ...>   time_in_force: "GTC"
      ...> }, %{})
      {:ok, %{symbol: "ETHUSDT", order_id: 67890, status: "NEW", ...}}
  """

  use Lux.Prism,
    name: "Binance Spot Create Order",
    description: "Places a new spot order on Binance exchange",
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
        type: %{
          type: :string,
          description: "Order type",
          enum: ["LIMIT", "MARKET", "STOP_LOSS", "STOP_LOSS_LIMIT", "TAKE_PROFIT", "TAKE_PROFIT_LIMIT"]
        },
        quantity: %{
          type: :number,
          description: "Order quantity in base asset"
        },
        quote_order_qty: %{
          type: :number,
          description: "Order quantity in quote asset (for MARKET orders)"
        },
        price: %{
          type: :string,
          description: "Order price (required for LIMIT orders)"
        },
        time_in_force: %{
          type: :string,
          description: "Time in force",
          enum: ["GTC", "IOC", "FOK"]
        },
        stop_price: %{
          type: :string,
          description: "Trigger price for stop orders"
        },
        new_client_order_id: %{
          type: :string,
          description: "Custom order ID"
        }
      },
      required: ["symbol", "side", "type"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        symbol: %{type: :string},
        order_id: %{type: :integer},
        client_order_id: %{type: :string},
        status: %{type: :string},
        executed_qty: %{type: :string},
        fills: %{type: :array}
      },
      required: ["symbol", "order_id", "status"]
    }

  alias Lux.Integrations.Binance.Client
  require Logger

  def handler(params, _ctx) do
    with {:ok, symbol} <- validate_required(params, :symbol),
         {:ok, side} <- validate_required(params, :side),
         {:ok, order_type} <- validate_required(params, :type),
         :ok <- validate_order_params(order_type, params) do

      Logger.info("Placing Binance spot order: #{side} #{order_type} #{symbol}")

      request_params = build_order_params(params)

      case Client.signed_post("/api/v3/order", request_params) do
        {:ok, result} ->
          Logger.info("Order placed successfully: #{result["orderId"]}")
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
            fills: result["fills"] || []
          }}

        {:error, {:rate_limited, retry_after}} ->
          {:error, "Rate limited. Retry after #{retry_after}ms"}

        {:error, {status, %{"code" => code, "msg" => msg}}} ->
          {:error, "Binance API error (#{status}): [#{code}] #{msg}"}

        {:error, error} ->
          {:error, "Failed to place order: #{inspect(error)}"}
      end
    end
  end

  defp validate_required(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "Missing or invalid #{key}"}
    end
  end

  defp validate_order_params("MARKET", params) do
    if Map.has_key?(params, :quantity) or Map.has_key?(params, :quote_order_qty) do
      :ok
    else
      {:error, "MARKET orders require quantity or quote_order_qty"}
    end
  end

  defp validate_order_params("LIMIT", params) do
    cond do
      not Map.has_key?(params, :quantity) -> {:error, "LIMIT orders require quantity"}
      not Map.has_key?(params, :price) -> {:error, "LIMIT orders require price"}
      not Map.has_key?(params, :time_in_force) -> {:error, "LIMIT orders require time_in_force"}
      true -> :ok
    end
  end

  defp validate_order_params(type, params) when type in ["STOP_LOSS", "TAKE_PROFIT"] do
    if Map.has_key?(params, :quantity) do
      :ok
    else
      {:error, "#{type} orders require quantity"}
    end
  end

  defp validate_order_params(type, params) when type in ["STOP_LOSS_LIMIT", "TAKE_PROFIT_LIMIT"] do
    cond do
      not Map.has_key?(params, :quantity) -> {:error, "#{type} orders require quantity"}
      not Map.has_key?(params, :price) -> {:error, "#{type} orders require price"}
      not Map.has_key?(params, :stop_price) -> {:error, "#{type} orders require stop_price"}
      true -> :ok
    end
  end

  defp validate_order_params(_, _), do: :ok

  defp build_order_params(params) do
    params
    |> Map.take([:symbol, :side, :type, :quantity, :quote_order_qty, :price,
                 :time_in_force, :stop_price, :new_client_order_id])
    |> Enum_into_string_values()
  end

  defp enum_into_string_values(map) do
    Map.new(map, fn
      {k, v} when is_number(v) -> {k, to_string(v)}
      {k, v} -> {k, v}
    end)
  end
end
