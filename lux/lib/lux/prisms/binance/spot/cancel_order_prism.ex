defmodule Lux.Prisms.Binance.Spot.CancelOrderPrism do
  @moduledoc """
  A prism for canceling active spot orders on Binance.

  ## Examples

      iex> Lux.Prisms.Binance.Spot.CancelOrderPrism.handler(%{
      ...>   symbol: "BTCUSDT",
      ...>   order_id: 12345
      ...> }, %{})
      {:ok, %{symbol: "BTCUSDT", order_id: 12345, status: "CANCELED"}}
  """

  use Lux.Prism,
    name: "Binance Spot Cancel Order",
    description: "Cancels an active spot order on Binance exchange",
    input_schema: %{
      type: :object,
      properties: %{
        symbol: %{
          type: :string,
          description: "Trading pair symbol"
        },
        order_id: %{
          type: :integer,
          description: "Order ID to cancel"
        },
        orig_client_order_id: %{
          type: :string,
          description: "Original client order ID (alternative to order_id)"
        },
        new_client_order_id: %{
          type: :string,
          description: "New client order ID for the cancel request"
        }
      },
      required: ["symbol"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        symbol: %{type: :string},
        order_id: %{type: :integer},
        status: %{type: :string}
      },
      required: ["symbol", "order_id", "status"]
    }

  alias Lux.Integrations.Binance.Client
  require Logger

  def handler(params, _ctx) do
    symbol = Map.fetch!(params, :symbol)

    request_params =
      params
      |> Map.take([:symbol, :order_id, :orig_client_order_id, :new_client_order_id])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    Logger.info("Canceling order on #{symbol}: #{inspect(request_params)}")

    case Client.signed_delete("/api/v3/order", request_params) do
      {:ok, result} ->
        {:ok, %{
          symbol: result["symbol"],
          order_id: result["orderId"],
          orig_client_order_id: result["origClientOrderId"],
          status: result["status"],
          price: result["price"],
          orig_qty: result["origQty"],
          executed_qty: result["executedQty"]
        }}

      {:error, {status, %{"code" => code, "msg" => msg}}} ->
        {:error, "Cancel failed (#{status}): [#{code}] #{msg}"}

      {:error, error} ->
        {:error, "Failed to cancel order: #{inspect(error)}"}
    end
  end
end
