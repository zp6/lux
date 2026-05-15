defmodule Lux.Lenses.Hyperliquid.FundingRateLens do
  @moduledoc """
  A lens for fetching current funding rates from Hyperliquid perpetual markets.

  ## Examples

      iex> Lux.Lenses.Hyperliquid.FundingRateLens.focus(%{})
      {:ok, %{rates: [%{coin: "ETH", funding_rate: 0.0001, ...}]}}
  """

  use Lux.Lens,
    name: "Hyperliquid Funding Rates",
    description: "Fetches current funding rates for all perpetual markets",
    url: "https://api.hyperliquid.xyz/info",
    method: :post,
    schema: %{
      type: :object,
      properties: %{
        coin: %{
          type: :string,
          description: "Optional coin filter (e.g., 'ETH'). Returns all if omitted."
        }
      }
    }

  def before_focus(params) do
    Map.put(params, :body, %{"type" => "metaAndAssetCtxs"})
  end

  def after_focus([_meta, asset_ctxs]) when is_list(asset_ctxs) do
    rates =
      asset_ctxs
      |> Enum.with_index()
      |> Enum.map(fn {ctx, idx} ->
        %{
          index: idx,
          funding_rate: parse_float(ctx["funding"]),
          open_interest: parse_float(ctx["openInterest"]),
          prev_day_px: parse_float(ctx["prevDayPx"]),
          day_ntl_vlm: parse_float(ctx["dayNtlVlm"]),
          premium: parse_float(ctx["premium"]),
          oracle_px: parse_float(ctx["oraclePx"])
        }
      end)

    {:ok, %{rate_count: length(rates), rates: rates}}
  end

  def after_focus(body), do: {:ok, body}

  defp parse_float(nil), do: 0.0
  defp parse_float(val) when is_float(val), do: val
  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end
