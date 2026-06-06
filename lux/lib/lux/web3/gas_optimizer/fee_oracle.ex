defmodule Lux.Web3.GasOptimizer.FeeOracle do
  @moduledoc """
  Multi-source gas price oracle that aggregates fees from multiple providers.

  Queries the configured RPC endpoint and optional public oracle APIs
  (e.g., Etherscan Gas Oracle), then returns a weighted average for
  more reliable gas price estimates.

  ## Configuration

      config :lux, Lux.Web3.GasOptimizer.FeeOracle,
        etherscan_api_key: System.get_env("ETHERSCAN_API_KEY"),
        rpc_weight: 0.6,
        oracle_weight: 0.4,
        oracle_cache_ttl_seconds: 30

  ## Usage

      {:ok, prices} = FeeOracle.estimate(:ethereum)
  """

  require Logger

  @doc """
  Estimates gas prices by querying multiple sources and averaging results.

  Falls back gracefully: if the RPC fails, uses oracle data; if oracle
  fails, uses RPC data; if both fail, returns an error.

  ## Returns

    * `{:ok, %{base_fee: ..., priority_fee: ..., max_fee: ..., sources_queried: ..., sources_responded: ..., chain: ...}}`
    * `{:error, reason}`
  """
  @spec estimate(atom()) :: {:ok, map()} | {:error, term()}
  def estimate(chain) do
    rpc_weight = rpc_weight()

    rpc_task = Task.async(fn -> fetch_rpc_prices(chain) end)
    oracle_task = Task.async(fn -> fetch_oracle_prices(chain) end)

    rpc_result = Task.await(rpc_task, 12_000)
    oracle_result = Task.await(oracle_task, 12_000)

    merge_results(chain, rpc_result, oracle_result, rpc_weight)
  end

  # --- Private ---

  defp fetch_rpc_prices(chain) do
    case Lux.Web3.GasOptimizer.get_gas_prices(chain) do
      {:ok, prices} ->
        {:ok, %{
          base_fee: Map.get(prices, :base_fee, 0),
          priority_fee: Map.get(prices, :priority_fee, 0),
          max_fee: Map.get(prices, :max_fee, 0),
          gas_price: Map.get(prices, :gas_price, 0)
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_oracle_prices(chain) do
    api_key = etherscan_api_key()

    if api_key == nil do
      Logger.debug("No etherscan API key configured, skipping oracle source")
      {:error, :no_oracle_api_key}
    else
      case fetch_etherscan_oracle(chain, api_key) do
        {:ok, prices} -> {:ok, prices}
        {:error, reason} ->
          Logger.warning("Etherscan oracle failed for #{chain}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp fetch_etherscan_oracle(chain, api_key) do
    oracle_urls = %{
      ethereum: "https://api.etherscan.io/api",
      polygon: "https://api.polygonscan.com/api"
    }

    base_url = Map.get(oracle_urls, chain)
    if base_url == nil do
      {:error, :no_oracle_for_chain}
    else
      params = [
        module: "gastracker",
        action: "gasoracle",
        apikey: api_key
      ]

      url = base_url <> "?" <> URI.encode_query(params)

      case Req.get(url, receive_timeout: 10_000) do
        {:ok, %Req.Response{status: 200, body: %{"result" => result}}} when is_map(result) ->
          parse_oracle_result(result)

        _ ->
          {:error, :oracle_request_failed}
      end
    end
  end

  defp parse_oracle_result(result) do
    safe_gwei = parse_float(result["SafeGasPrice"] || "0")
    propose_gwei = parse_float(result["ProposeGasPrice"] || "0")
    fast_gwei = parse_float(result["FastGasPrice"] || "0")

    suggest_gwei = max(propose_gwei, safe_gwei)
    base_fee_wei = trunc(suggest_gwei * 1_000_000_000)
    priority_fee_wei = trunc(safe_gwei * 1_000_000_000)
    max_fee_wei = trunc(fast_gwei * 1_000_000_000)

    {:ok, %{
      base_fee: base_fee_wei,
      priority_fee: priority_fee_wei,
      max_fee: max_fee_wei,
      gas_price: 0,
      oracle_safe_gwei: safe_gwei,
      oracle_propose_gwei: propose_gwei,
      oracle_fast_gwei: fast_gwei
    }}
  end

  defp merge_results(chain, rpc_result, oracle_result, rpc_weight) do
    rpc_ok? = match?({:ok, _}, rpc_result)
    oracle_ok? = match?({:ok, _}, oracle_result)

    sources_queried = if rpc_ok?, do: 1, else: 0
    sources_queried = if oracle_ok?, do: sources_queried + 1, else: sources_queried

    cond do
      rpc_ok? and oracle_ok? ->
        {:ok, rpc_prices} = rpc_result
        {:ok, oracle_prices} = oracle_result
        oracle_weight = 1.0 - rpc_weight

        averaged = %{
          base_fee: weighted_avg(rpc_prices.base_fee, oracle_prices.base_fee, rpc_weight, oracle_weight),
          priority_fee: weighted_avg(rpc_prices.priority_fee, oracle_prices.priority_fee, rpc_weight, oracle_weight),
          max_fee: weighted_avg(rpc_prices.max_fee, oracle_prices.max_fee, rpc_weight, oracle_weight),
          sources_queried: sources_queried,
          sources_responded: sources_queried,
          chain: chain
        }

        {:ok, averaged}

      rpc_ok? ->
        {:ok, rpc_prices} = rpc_result
        {:ok, Map.put(rpc_prices, :sources_queried, sources_queried)
                  |> Map.put(:sources_responded, 1)
                  |> Map.put(:chain, chain)}

      oracle_ok? ->
        {:ok, oracle_prices} = oracle_result
        {:ok, Map.put(oracle_prices, :sources_queried, sources_queried)
                  |> Map.put(:sources_responded, 1)
                  |> Map.put(:chain, chain)}

      true ->
        {:error, {:all_sources_failed, chain}}
    end
  end

  defp weighted_avg(a, b, w_a, w_b) do
    trunc(a * w_a + b * w_b)
  end

  defp parse_float(str) when is_binary(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> 0.0
    end
  end
  defp parse_float(_), do: 0.0

  defp rpc_weight do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:rpc_weight, 0.6)
  end

  defp etherscan_api_key do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:etherscan_api_key)
  end
end
