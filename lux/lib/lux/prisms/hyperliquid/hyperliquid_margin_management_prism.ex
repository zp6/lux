defmodule Lux.Prisms.Hyperliquid.HyperliquidMarginManagementPrism do
  @moduledoc """
  A prism for managing margin on Hyperliquid perpetual positions.

  Supports adding/removing margin from isolated positions.

  ## Examples

      iex> Lux.Prisms.Hyperliquid.HyperliquidMarginManagementPrism.handler(%{
      ...>   coin: "ETH", amount: 100.0, action: "add"
      ...> }, %{})
      {:ok, %{status: "success", coin: "ETH", margin_change: 100.0}}
  """

  use Lux.Prism,
    name: "Hyperliquid Margin Management",
    description: "Manages margin for Hyperliquid perpetual positions",
    input_schema: %{
      type: :object,
      properties: %{
        coin: %{type: :string, description: "Trading pair symbol"},
        amount: %{type: :number, description: "Margin amount in USD"},
        action: %{type: :string, description: "'add' or 'remove'", enum: ["add", "remove"]}
      },
      required: ["coin", "amount", "action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        status: %{type: :string},
        coin: %{type: :string},
        margin_change: %{type: :number}
      },
      required: ["status", "coin", "margin_change"]
    }

  import Lux.Python
  alias Lux.Config
  require Logger

  def handler(input, _ctx) do
    with {:ok, private_key} <- get_private_key(),
         {:ok, address} <- {:ok, Config.hyperliquid_account_address()},
         {:ok, api_url} <- {:ok, Config.hyperliquid_api_url()},
         {:ok, _} <- validate_action(input.action) do

      Logger.info("#{String.upcase(input.action)} margin #{input.amount} for #{input.coin}")

      result = python variables: %{
        private_key: private_key, address: address, api_url: api_url,
        coin: input.coin, amount: input.amount, action: input.action
      } do
        ~PY"""
        from hyperliquid.exchange import Exchange
        from hyperliquid_utils.setup import setup

        address, info, exchange = setup(private_key, address, api_url, skip_ws=True)

        if action == "add":
            result = exchange.update_isolated_margin(coin, True, float(amount))
        else:
            result = exchange.update_isolated_margin(coin, False, float(amount))

        {"result": result}
        """
      end

      case result do
        %{"result" => %{"status" => "ok"}} ->
          {:ok, %{status: "success", coin: input.coin, margin_change: input.amount}}
        %{"result" => result} ->
          {:ok, %{status: "success", coin: input.coin, margin_change: input.amount, raw: result}}
        %{"error" => error} ->
          {:error, "Margin operation failed: #{error}"}
      end
    end
  end

  defp get_private_key do
    {:ok, Config.hyperliquid_account_key()}
  rescue
    RuntimeError -> {:error, :missing_private_key}
  end

  defp validate_action(action) when action in ["add", "remove"], do: {:ok, action}
  defp validate_action(action), do: {:error, "Invalid action: #{action}"}
end
