defmodule Lux.Prisms.Hyperliquid.HyperliquidSetLeveragePrism do
  @moduledoc """
  A prism for setting leverage on Hyperliquid perpetual positions.

  ## Examples

      iex> Lux.Prisms.Hyperliquid.HyperliquidSetLeveragePrism.handler(%{
      ...>   coin: "ETH", leverage: 5, is_cross: true
      ...> }, %{})
      {:ok, %{status: "success", coin: "ETH", leverage: 5}}
  """

  use Lux.Prism,
    name: "Hyperliquid Set Leverage",
    description: "Sets leverage for a perpetual trading pair on Hyperliquid",
    input_schema: %{
      type: :object,
      properties: %{
        coin: %{type: :string, description: "Trading pair symbol"},
        leverage: %{type: :integer, description: "Desired leverage (1-50)", minimum: 1, maximum: 50},
        is_cross: %{type: :boolean, description: "Cross margin (true) or isolated (false)", default: true}
      },
      required: ["coin", "leverage"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        status: %{type: :string},
        coin: %{type: :string},
        leverage: %{type: :integer}
      },
      required: ["status", "coin", "leverage"]
    }

  import Lux.Python
  alias Lux.Config
  require Logger

  def handler(input, _ctx) do
    with {:ok, private_key} <- get_private_key(),
         {:ok, address} <- {:ok, Config.hyperliquid_account_address()},
         {:ok, api_url} <- {:ok, Config.hyperliquid_api_url()} do

      Logger.info("Setting leverage for #{input.coin} to #{input.leverage}x")

      result = python variables: %{
        private_key: private_key,
        address: address,
        api_url: api_url,
        coin: input.coin,
        leverage: input.leverage,
        is_cross: Map.get(input, :is_cross, true)
      } do
        ~PY"""
        from hyperliquid.exchange import Exchange
        from hyperliquid_utils.setup import setup

        address, info, exchange = setup(private_key, address, api_url, skip_ws=True)
        result = exchange.update_leverage(leverage, coin, is_cross)
        {"result": result}
        """
      end

      case result do
        %{"result" => %{"status" => "ok"}} ->
          {:ok, %{status: "success", coin: input.coin, leverage: input.leverage}}
        %{"result" => result} ->
          {:ok, %{status: "success", coin: input.coin, leverage: input.leverage, raw: result}}
        %{"error" => error} ->
          {:error, "Failed to set leverage: #{error}"}
      end
    end
  end

  defp get_private_key do
    {:ok, Config.hyperliquid_account_key()}
  rescue
    RuntimeError -> {:error, :missing_private_key}
  end
end
