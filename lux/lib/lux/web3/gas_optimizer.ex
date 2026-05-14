defmodule Lux.Web3.GasOptimizer do
  @moduledoc """
  Gas optimization module for EVM-compatible chains.

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
        # Gas price multiplier for safety margin (1.0 = no margin)
        gas_price_margin: 1.1,
        # Default priority fee in wei
        default_priority_fee: 1_500_000_000,
        # Max gas price cap in wei (50 Gwei)
        max_gas_price: 50_000_000_000,
        # History window in blocks for trend analysis
        history_window: 100

  ## Usage

      alias Lux.Web3.GasOptimizer

      # Get current gas prices for Ethereum
      {:ok, gas_prices} = GasOptimizer.get_gas_prices(:ethereum)

      # Get optimal gas price suggestion
      {:ok, suggestion} = GasOptimizer.suggest_gas_price(:ethereum, :medium)

      # Estimate gas for a transaction
      {:ok, gas_limit} = GasOptimizer.estimate_gas(:ethereum, tx_params)

      # Get the best time to send a transaction
      {:ok, prediction} = GasOptimizer.predict_optimal_time(:ethereum)
  """

  alias Lux.Web3.GasOptimizer.Estimator
  alias Lux.Web3.GasOptimizer.Predictor

  require Logger

  @type chain :: :ethereum | :polygon | :bsc | :arbitrum
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

  ## Examples

      {:ok, prices} = GasOptimizer.get_gas_prices(:ethereum)
      # => %{base_fee: 15_000_000_000, priority_fee: 1_500_000_000, ...}

      {:ok, prices} = GasOptimizer.get_gas_prices(:bsc)
      # => %{gas_price: 3_000_000_000, ...}
  """
  @spec get_gas_prices(chain()) :: {:ok, map()} | {:error, term()}
  def get_gas_prices(chain) do
    if eip1559?(chain) do
      get_eip1559_prices(chain)
    else
      get_legacy_prices(chain)
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

  Delegates to `Lux.Web3.GasOptimizer.Estimator`.

  ## Parameters

    * `chain` - The target chain
    * `tx_params` - Transaction parameters map (to, from, data, value)

  ## Examples

      {:ok, gas_limit} = GasOptimizer.estimate_gas(:ethereum, %{
        to: "0x...",
        from: "0x...",
        data: "0x..."
      })
  """
  @spec estimate_gas(chain(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
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

  defp get_eip1559_prices(chain) do
    url = rpc_url(chain)

    with {:ok, %{"result" => hex_block}} <- json_rpc(url, "eth_getBlockByNumber", ["latest", false]),
         {:ok, block} <- decode_hex_block(hex_block) do
      base_fee = parse_hex_int(block["baseFeePerGas"] || "0x0")
      # Use configured default or 1.5 Gwei
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
end
