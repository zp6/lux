defmodule Lux.Web3.GasOptimizer do
  @moduledoc """
  Gas optimization module for EVM-compatible chains and non-EVM chains.

  Provides real-time gas price monitoring (EIP-1559 base fee + priority fee),
  gas price prediction based on historical trends, transaction batching, and
  gas limit estimation across multiple chains.

  ## Supported Chains

  | Chain     | Chain ID | Type       |
  |-----------|----------|------------|
  | Ethereum  | 1        | EIP-1559   |
  | Polygon   | 137      | EIP-1559   |
  | BSC       | 56       | Legacy     |
  | Arbitrum  | 42161    | EIP-1559   |
  | Solana    | -        | Non-EVM    |
  | Near      | -        | Non-EVM    |

  ## Configuration

  Add to your `config/runtime.exs`:

      config :lux, Lux.Web3.GasOptimizer,
        rpc_urls: %{
          ethereum: System.get_env("ETHEREUM_RPC_URL") || "https://eth.llamarpc.com",
          polygon: System.get_env("POLYGON_RPC_URL") || "https://polygon-rpc.com",
          bsc: System.get_env("BSC_RPC_URL") || "https://bsc-dataseed.binance.org",
          arbitrum: System.get_env("ARBITRUM_RPC_URL") || "https://arb1.arbitrum.io/rpc"
        },
        default_chain: :ethereum,
        gas_price_margin: 1.1,
        default_priority_fee: 1_500_000_000,
        max_gas_price: 50_000_000_000,
        history_window: 100

  ## Usage

      alias Lux.Web3.GasOptimizer

      # Get current gas prices for Ethereum
      {:ok, gas_prices} = GasOptimizer.get_gas_prices(:ethereum)

      # Get optimal gas price suggestion
      {:ok, suggestion} = GasOptimizer.suggest_gas_price(:ethereum, :medium)

      # Estimate gas for a transaction
      {:ok, {gas_limit, meta}} = GasOptimizer.estimate_gas(:ethereum, tx_params)

      # Get the best time to send a transaction
      {:ok, prediction} = GasOptimizer.predict_optimal_time(:ethereum)

      # Replace a stuck transaction with higher fees
      {:ok, replacement} = GasOptimizer.replace_transaction(stuck_tx, :eip1559)

      # Get base fee history for EIP-1559 fee estimation
      {:ok, history} = GasOptimizer.base_fee_history(:ethereum)

      # Get gas prices from multi-source oracle
      {:ok, prices} = GasOptimizer.oracle_gas_prices(:ethereum)

      # Optimize a transaction (estimate + suggest fees)
      {:ok, gas_estimate} = GasOptimizer.optimize(:ethereum, tx_params)
  """

  alias Lux.Web3.GasOptimizer.Estimator
  alias Lux.Web3.GasOptimizer.Predictor
  alias Lux.Web3.GasOptimizer.Replacement
  alias Lux.Web3.GasOptimizer.FeeOracle

  require Logger

  @type chain :: :ethereum | :polygon | :bsc | :arbitrum | :solana | :near | :sui | :aptos
  @type speed :: :slow | :medium | :fast | :instant
  @type wei :: non_neg_integer()
  @type gas_prices :: %{
          base_fee: wei(),
          priority_fee: wei(),
          max_fee: wei(),
          estimated_confirmation_seconds: non_neg_integer(),
          chain: chain()
        }

  @chain_ids %{
    ethereum: 1,
    polygon: 137,
    bsc: 56,
    arbitrum: 42161
  }

  @eip1559_chains [:ethereum, :polygon, :arbitrum]
  @legacy_chains [:bsc]
  @non_evm_chains [:solana, :near, :sui, :aptos]

  # Speed multipliers for priority fee
  @speed_multipliers %{
    slow: 0.8,
    medium: 1.0,
    fast: 1.5,
    instant: 2.0
  }

  # Speed confirmation time estimates in seconds
  @confirmation_estimates %{
    slow: 300,
    medium: 60,
    fast: 30,
    instant: 15
  }

  @doc """
  Returns the chain ID for a given chain atom.
  """
  @spec chain_id(chain()) :: pos_integer()
  def chain_id(chain) do
    Map.fetch!(@chain_ids, chain)
  end

  @doc """
  Returns whether a chain supports EIP-1559 transactions.
  """
  @spec eip1559?(chain()) :: boolean()
  def eip1559?(chain), do: chain in @eip1559_chains

  @doc """
  Checks whether a chain is a known legacy (non-EIP-1559 EVM) chain.
  """
  @spec known_legacy?(atom()) :: boolean()
  def known_legacy?(chain), do: chain in @legacy_chains

  @doc """
  Checks whether a chain is a known non-EVM chain.
  """
  @spec non_evm?(atom()) :: boolean()
  def non_evm?(chain), do: chain in @non_evm_chains

  @doc """
  Gets the RPC URL for a given chain.
  """
  @spec rpc_url(chain()) :: String.t()
  def rpc_url(chain) do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> get_in([:rpc_urls, chain])
    |> case do
      nil -> raise "RPC URL not configured for chain #{chain}"
      url -> url
    end
  end

  @doc """
  Gets the default chain from configuration.
  """
  @spec default_chain() :: chain()
  def default_chain do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:default_chain, :ethereum)
  end

  @doc """
  Fetches current gas prices for the specified chain.

  For EIP-1559 chains, returns base fee, priority fee, and max fee.
  For legacy chains (BSC), returns a single gas price.
  For non-EVM chains, returns a chain-specific gas price estimate.

  ## Examples

      {:ok, prices} = GasOptimizer.get_gas_prices(:ethereum)
      {:ok, prices} = GasOptimizer.get_gas_prices(:bsc)
      {:ok, prices} = GasOptimizer.get_gas_prices(:solana)
  """
  @spec get_gas_prices(chain()) :: {:ok, map()} | {:error, term()}
  def get_gas_prices(chain) do
    cond do
      eip1559?(chain) -> get_eip1559_prices(chain)
      known_legacy?(chain) -> get_legacy_prices(chain)
      non_evm?(chain) -> get_non_evm_prices(chain)
      true -> {:error, {:unsupported_chain, chain}}
    end
  end

  @doc """
  Suggests an optimal gas price for the given chain and speed.

  Combines current network conditions with historical trend analysis
  to suggest a gas price that balances cost and confirmation speed.

  ## Parameters

    * `chain` - The target chain
    * `speed` - Desired confirmation speed (:slow, :medium, :fast, :instant)

  ## Examples

      {:ok, suggestion} = GasOptimizer.suggest_gas_price(:ethereum, :fast)
  """
  @spec suggest_gas_price(chain(), speed()) :: {:ok, map()} | {:error, term()}
  def suggest_gas_price(chain, speed \\ :medium) do
    margin = gas_price_margin()
    multiplier = Map.fetch!(@speed_multipliers, speed)

    with {:ok, prices} <- get_gas_prices(chain) do
      suggestion =
        if eip1559?(chain) do
          priority_fee = trunc(prices.priority_fee * multiplier * margin)
          max_fee = trunc(prices.max_fee * multiplier * margin)
          max_fee = min(max_fee, max_gas_price())

          %{
            base_fee: prices.base_fee,
            priority_fee: priority_fee,
            max_fee: max_fee,
            max_priority_fee_per_gas: priority_fee,
            max_fee_per_gas: max_fee,
            estimated_confirmation_seconds: Map.get(@confirmation_estimates, speed, 60),
            chain: chain,
            speed: speed
          }
        else
          gas_price = trunc(prices.gas_price * multiplier * margin)
          gas_price = min(gas_price, max_gas_price())

          %{
            gas_price: gas_price,
            estimated_confirmation_seconds: Map.get(@confirmation_estimates, speed, 60),
            chain: chain,
            speed: speed
          }
        end

      {:ok, suggestion}
    end
  end

  @doc """
  Estimates the gas limit for a transaction.

  Delegates to `Lux.Web3.GasOptimizer.Estimator.estimate/2`.

  ## Parameters

    * `chain` - The target chain
    * `tx_params` - Transaction parameters map (to, from, data, value)

  ## Returns

    * `{:ok, {gas_limit, meta}}` - Gas estimate with metadata
    * `{:error, reason}` - Estimation failed

  ## Examples

      {:ok, {gas_limit, meta}} = GasOptimizer.estimate_gas(:ethereum, %{
        to: "0x...",
        from: "0x...",
        data: "0x..."
      })

      gas_limit        # => 65_000 (with margin applied)
      meta.source      # => :rpc or :cached
      meta.anomaly      # => true or false
      meta.raw_estimate # => original estimate before margin
  """
  @spec estimate_gas(chain(), map()) ::
          {:ok, {non_neg_integer(), Estimator.estimate_meta()}} | {:error, term()}
  defdelegate estimate_gas(chain, tx_params), to: Estimator

  @doc """
  Predicts the optimal time to send a transaction.

  Delegates to `Lux.Web3.GasOptimizer.Predictor`.

  ## Examples

      {:ok, prediction} = GasOptimizer.predict_optimal_time(:ethereum)
      # => %{suggested_wait_seconds: 1800, current_trend: :decreasing, ...}
  """
  @spec predict_optimal_time(chain()) :: {:ok, map()} | {:error, term()}
  defdelegate predict_optimal_time(chain), to: Predictor

  @doc """
  Replaces a stuck transaction with higher fees.

  Creates a replacement transaction that keeps the same nonce but increases
  gas fees by at least the network-required minimum (10%).

  ## Returns

    * `{:ok, replacement_tx}` - Replacement transaction with bumped fees
    * `{:error, reason}` - Replacement failed
  """
  @spec replace_transaction(map(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def replace_transaction(tx, tx_type, opts \\ []) do
    Replacement.bump_fees(tx, tx_type, opts)
  end

  @doc """
  Fetches base fee history from recent blocks for EIP-1559 fee estimation.

  Retrieves base fees from the last N blocks to support fee trend analysis
  and more accurate estimation.

  ## Returns

    * `{:ok, [%{block_number: pos_integer(), base_fee: non_neg_integer(), timestamp: non_neg_integer()}]}`
    * `{:error, {:not_eip1559, chain}}`
  """
  @spec base_fee_history(atom(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def base_fee_history(chain, block_count \\ nil) do
    unless eip1559?(chain) do
      {:error, {:not_eip1559, chain}}
    else
      count = block_count || history_window()
      url = rpc_url(chain)

      with {:ok, %{"result" => hex_latest}} <- json_rpc(url, "eth_blockNumber", []) do
        latest = parse_hex_int(hex_latest)

        block_numbers =
          (latest - count + 1)..latest
          |> Enum.to_list()

        base_fees =
          block_numbers
          |> Enum.map(fn num ->
            case json_rpc(url, "eth_getBlockByNumber", [encode_hex_int(num), false]) do
              {:ok, %{"result" => block}} when is_map(block) ->
                %{
                  block_number: num,
                  base_fee: parse_hex_int(block["baseFeePerGas"] || "0x0"),
                  timestamp: parse_hex_int(block["timestamp"] || "0x0")
                }

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, base_fees}
      else
        {:error, reason} ->
          {:error, {:base_fee_history_failed, chain, reason}}
      end
    end
  end

  @doc """
  Estimates priority fee based on recent block history.

  Analyzes miner reward data from recent blocks to estimate an appropriate
  priority fee that will get included in the next block.
  """
  @spec estimate_priority_fee(atom()) :: {:ok, non_neg_integer()} | {:error, term()}
  def estimate_priority_fee(chain) do
    unless eip1559?(chain) do
      {:error, {:not_eip1559, chain}}
    else
      url = rpc_url(chain)
      window = min(history_window(), 10)

      with {:ok, %{"result" => hex_latest}} <- json_rpc(url, "eth_blockNumber", []) do
        latest = parse_hex_int(hex_latest)

        tips =
          (latest - window + 1)..latest
          |> Enum.map(fn num ->
            case json_rpc(url, "eth_getBlockByNumber", [encode_hex_int(num), true]) do
              {:ok, %{"result" => block}} when is_map(block) ->
                extract_miner_tip(block)

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        case tips do
          [] -> {:ok, default_priority_fee()}
          _ ->
            median = median_value(Enum.sort(tips))
            {:ok, max(median, default_priority_fee())}
        end
      else
        {:error, reason} ->
          {:error, {:priority_fee_estimation_failed, chain, reason}}
      end
    end
  end

  @doc """
  Fetches gas prices from multiple sources and returns an averaged result.

  Queries the configured RPC endpoint and optional public gas price oracles,
  then averages the results for more reliable pricing.
  """
  @spec oracle_gas_prices(atom()) :: {:ok, map()} | {:error, term()}
  def oracle_gas_prices(chain) do
    FeeOracle.estimate(chain)
  end

  @doc """
  Optimizes a transaction for gas efficiency.

  Estimates gas and suggests optimal fee parameters.

  ## Returns

    * `{:ok, gas_estimate}` - A map with `gas_limit`, `meta`, and `suggestion`
    * `{:error, reason}` - Optimization failed
  """
  @spec optimize(atom(), map()) :: {:ok, map()} | {:error, term()}
  def optimize(chain, tx_params) do
    with {:ok, {gas_limit, meta}} <- estimate_gas(chain, tx_params),
         {:ok, suggestion} <- suggest_gas_price(chain, :medium) do
      {:ok, %{
        gas_limit: gas_limit,
        meta: meta,
        suggestion: suggestion
      }}
    end
  end

  @doc """
  Gets the configured gas price margin.
  """
  @spec gas_price_margin() :: float()
  def gas_price_margin do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:gas_price_margin, 1.1)
  end

  @doc """
  Gets the configured max gas price cap.
  """
  @spec max_gas_price() :: wei()
  def max_gas_price do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_gas_price, 50_000_000_000)
  end

  @doc """
  Gets the configured default priority fee.
  """
  @spec default_priority_fee() :: wei()
  def default_priority_fee do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:default_priority_fee, 1_500_000_000)
  end

  @doc """
  Gets the configured history window in blocks.
  """
  @spec history_window() :: pos_integer()
  def history_window do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:history_window, 100)
  end

  # --- Private Functions ---

  defp get_non_evm_prices(chain) do
    Logger.info("Using non-EVM gas price estimation for #{chain}")

    base_prices = %{
      solana: 50_000,
      near: 1_000_000_000,
      sui: 750,
      aptos: 100
    }

    gas_price = Map.get(base_prices, chain, 0)

    if gas_price == 0 do
      {:error, {:unsupported_non_evm, chain}}
    else
      {:ok, %{
        gas_price: gas_price,
        chain: chain
      }}
    end
  end

  defp get_eip1559_prices(chain) do
    url = rpc_url(chain)

    with {:ok, %{"result" => hex_block}} <- json_rpc(url, "eth_getBlockByNumber", ["latest", false]),
         {:ok, block} <- decode_hex_block(hex_block) do
      base_fee = parse_hex_int(block["baseFeePerGas"] || "0x0")
      priority_fee = default_priority_fee()
      max_fee = base_fee * 2 + priority_fee

      {:ok,
       %{
         base_fee: base_fee,
         priority_fee: priority_fee,
         max_fee: max_fee,
         chain: chain
       }}
    else
      {:error, reason} ->
        Logger.error("Failed to fetch EIP-1559 gas prices for #{chain}: #{inspect(reason)}")
        {:error, {:gas_price_fetch_failed, chain, reason}}
    end
  end

  defp get_legacy_prices(chain) do
    url = rpc_url(chain)

    with {:ok, %{"result" => hex_gas_price}} <- json_rpc(url, "eth_gasPrice", []) do
      gas_price = parse_hex_int(hex_gas_price)

      {:ok,
       %{
         gas_price: gas_price,
         chain: chain
       }}
    else
      {:error, reason} ->
        Logger.error("Failed to fetch legacy gas prices for #{chain}: #{inspect(reason)}")
        {:error, {:gas_price_fetch_failed, chain, reason}}
    end
  end

  defp json_rpc(url, method, params) do
    body = Jason.encode!(%{
      jsonrpc: "2.0",
      id: 1,
      method: method,
      params: params
    })

    headers = [{"content-type", "application/json"}]

    case Req.post(url, body: body, headers: headers, receive_timeout: 10_000) do
      {:ok, %Req.Response{status: 200, body: %{"error" => error}}} ->
        {:error, {:rpc_error, error}}

      {:ok, %Req.Response{status: 200, body: response}} ->
        {:ok, response}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp decode_hex_block(hex_block) when is_map(hex_block), do: {:ok, hex_block}
  defp decode_hex_block(_), do: {:error, :invalid_block}

  defp parse_hex_int("0x" <> hex), do: String.to_integer(hex, 16)
  defp parse_hex_int(_), do: 0

  defp encode_hex_int(n), do: "0x" <> Integer.to_string(n, 16)

  defp extract_miner_tip(block) do
    case block["transactions"] do
      txs when is_list(txs) ->
        txs
        |> Enum.take(5)
        |> Enum.map(fn
          tx when is_map(tx) ->
            ef = tx["effectiveGasPrice"]
            if ef, do: parse_hex_int(ef), else: nil

          _tx when is_binary(_tx) ->
            nil
        end)
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> nil
          fees -> Enum.min(fees)
        end

      _ ->
        nil
    end
  end

  defp median_value([]), do: 0
  defp median_value(sorted) when is_list(sorted) do
    len = length(sorted)
    mid = div(len, 2)

    if rem(len, 2) == 1 do
      Enum.at(sorted, mid)
    else
      div(Enum.at(sorted, mid - 1) + Enum.at(sorted, mid), 2)
    end
  end
end
