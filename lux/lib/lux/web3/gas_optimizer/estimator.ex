defmodule Lux.Web3.GasOptimizer.Estimator do
  @moduledoc """
  Gas limit estimation with historical tracking and anomaly detection.

  Estimates gas limits for transactions based on:
  - RPC `eth_estimateGas` calls for accurate on-chain simulation
  - Historical gas usage per contract method for cached estimates
  - Configurable safety margins to prevent out-of-gas errors
  - Anomaly detection when estimates deviate significantly from history

  ## Configuration

      config :lux, Lux.Web3.GasOptimizer.Estimator,
        # Default safety margin percentage (10%)
        default_margin_percent: 10,
        # Maximum allowed margin (50%)
        max_margin_percent: 50,
        # Anomaly threshold: flag if estimate exceeds this multiple of historical average
        anomaly_threshold: 2.0,
        # Minimum gas limit for any transaction
        min_gas_limit: 21_000,
        # Maximum gas limit cap
        max_gas_limit: 10_000_000

  ## Usage

      alias Lux.Web3.GasOptimizer.Estimator

      # Estimate gas for a transaction
      {:ok, {gas_limit, meta}} = Estimator.estimate(:ethereum, %{
        to: "0xContractAddress",
        from: "0xSenderAddress",
        data: "0xabcdef..."
      })

      # Record historical gas usage for smarter future estimates
      :ok = Estimator.record_usage(:ethereum, "0xContractAddress", "transfer", 65_000)
  """

  require Logger

  @type gas_limit :: non_neg_integer()
  @type method_id :: String.t()
  @type contract_address :: String.t()

  @type estimate_meta :: %{
          source: :rpc | :cached,
          raw_estimate: gas_limit(),
          margin_percent: non_neg_integer(),
          anomaly: boolean()
        }

  @doc """
  Estimates gas limit for a transaction.

  First attempts an RPC `eth_estimateGas` call. Falls back to historical
  data if the RPC call fails. Applies a safety margin and checks for anomalies.

  ## Parameters

    * `chain` - Target chain atom (:ethereum, :polygon, :bsc, :arbitrum)
    * `tx_params` - Map with `:to`, `:from`, `:data` (optional `:value`)

  ## Returns

    * `{:ok, {gas_limit, meta}}` - Successful estimate with metadata
    * `{:error, reason}` - Estimation failed

  ## Examples

      {:ok, {gas_limit, meta}} = Estimator.estimate(:ethereum, %{
        to: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
        from: "0xSender",
        data: "0xa9059cbb000000000000000000000000..."
      })

      gas_limit  # => 65_000 (with 10% margin applied)
      meta.source  # => :rpc
      meta.anomaly  # => false
  """
  @spec estimate(atom(), map()) :: {:ok, {gas_limit(), estimate_meta()}} | {:error, term()}
  def estimate(chain, tx_params) do
    margin_percent = margin_percent()
    min_gas = min_gas_limit()
    max_gas = max_gas_limit()

    case rpc_estimate(chain, tx_params) do
      {:ok, raw_estimate} ->
        {gas_limit, anomaly} =
          apply_margin(raw_estimate, margin_percent, min_gas, max_gas)
          |> check_anomaly(chain, tx_params[:to], extract_method_id(tx_params[:data]))

        meta = %{
          source: :rpc,
          raw_estimate: raw_estimate,
          margin_percent: margin_percent,
          anomaly: anomaly
        }

        {:ok, {gas_limit, meta}}

      {:error, _rpc_error} ->
        # Fallback to historical estimate
        contract = tx_params[:to]
        method = extract_method_id(tx_params[:data])

        case historical_estimate(chain, contract, method) do
          {:ok, raw_estimate} ->
            {gas_limit, anomaly} =
              apply_margin(raw_estimate, margin_percent * 2, min_gas, max_gas)
              |> check_anomaly(chain, contract, method)

            meta = %{
              source: :cached,
              raw_estimate: raw_estimate,
              margin_percent: margin_percent * 2,
              anomaly: anomaly
            }

            {:ok, {gas_limit, meta}}

          :error ->
            # Ultimate fallback: standard transfer gas limit with margin
            fallback = apply_margin(21_000, margin_percent, min_gas, max_gas)

            {:ok, {fallback, %{
              source: :cached,
              raw_estimate: 21_000,
              margin_percent: margin_percent,
              anomaly: false
            }}}
        end
    end
  end

  @doc """
  Records actual gas usage for a contract method.

  Stores the value in an ETS-backed history table for future reference.
  Keeps only the last 100 entries per {chain, contract, method} key.

  ## Examples

      :ok = Estimator.record_usage(:ethereum, "0xContract", "transfer", 55_000)
  """
  @spec record_usage(atom(), contract_address(), method_id(), gas_limit()) :: :ok
  def record_usage(chain, contract, method, gas_used) do
    ensure_table()
    key = {chain, String.downcase(contract || ""), method || "unknown"}

    existing =
      case :ets.lookup(:gas_estimator_history, key) do
        [{^key, entries}] -> entries
        [] -> []
      end

    # Keep last 100 entries
    updated =
      [gas_used | existing]
      |> Enum.take(100)

    :ets.insert(:gas_estimator_history, {key, updated})
    :ok
  end

  @doc """
  Gets historical gas usage statistics for a contract method.

  ## Returns

    * `{:ok, %{avg: float, min: integer, max: integer, count: integer}}`
    * `:error` if no history exists

  ## Examples

      {:ok, stats} = Estimator.get_history(:ethereum, "0xContract", "transfer")
      # => %{avg: 55230.5, min: 51000, max: 65000, count: 20}
  """
  @spec get_history(atom(), contract_address(), method_id()) :: {:ok, map()} | :error
  def get_history(chain, contract, method) do
    ensure_table()
    key = {chain, String.downcase(contract || ""), method || "unknown"}

    case :ets.lookup(:gas_estimator_history, key) do
      [{^key, entries}] when entries != [] ->
        {:ok, %{
          avg: Enum.sum(entries) / length(entries),
          min: Enum.min(entries),
          max: Enum.max(entries),
          count: length(entries)
        }}

      _ ->
        :error
    end
  end

  @doc """
  Clears all historical gas usage data.
  """
  @spec clear_history() :: :ok
  def clear_history do
    ensure_table()
    :ets.delete_all_objects(:gas_estimator_history)
    :ok
  end

  # --- Configuration Helpers ---

  @spec margin_percent() :: non_neg_integer()
  defp margin_percent do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:default_margin_percent, 10)
  end

  @spec min_gas_limit() :: non_neg_integer()
  defp min_gas_limit do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:min_gas_limit, 21_000)
  end

  @spec max_gas_limit() :: non_neg_integer()
  defp max_gas_limit do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_gas_limit, 10_000_000)
  end

  @spec anomaly_threshold() :: float()
  defp anomaly_threshold do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:anomaly_threshold, 2.0)
  end

  # --- Private Functions ---

  defp ensure_table do
    if :ets.whereis(:gas_estimator_history) == :undefined do
      :ets.new(:gas_estimator_history, [:named_table, :public, :set])
    end
  end

  defp rpc_estimate(chain, tx_params) do
    url = Lux.Web3.GasOptimizer.rpc_url(chain)

    params = %{
      to: tx_params[:to],
      from: tx_params[:from]
    }
    |> maybe_put(:data, tx_params[:data])
    |> maybe_put(:value, tx_params[:value])

    body = Jason.encode!(%{
      jsonrpc: "2.0",
      id: 1,
      method: "eth_estimateGas",
      params: [params]
    })

    case Req.post(url, body: body, headers: [{"content-type", "application/json"}], receive_timeout: 15_000) do
      {:ok, %Req.Response{status: 200, body: %{"result" => hex_gas}}} ->
        {:ok, parse_hex_int(hex_gas)}

      {:ok, %Req.Response{status: 200, body: %{"error" => error}}} ->
        {:error, {:rpc_error, error}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp historical_estimate(chain, contract, method) do
    case get_history(chain, contract, method) do
      {:ok, %{avg: avg, max: max_val}} ->
        # Use the higher of average or max, with a small buffer
        {:ok, max(trunc(avg), max_val)}

      :error ->
        :error
    end
  end

  defp apply_margin(raw, margin_percent, min_gas, max_gas) do
    raw
    |> Kernel.*(1 + margin_percent / 100)
    |> trunc()
    |> max(min_gas)
    |> min(max_gas)
  end

  defp check_anomaly({gas_limit, _} = result, chain, contract, method) do
    threshold = anomaly_threshold()

    case get_history(chain, contract, method) do
      {:ok, %{avg: avg}} when avg > 0 ->
        anomaly = gas_limit > avg * threshold
        if anomaly do
          Logger.warning(
            "Gas estimate anomaly detected for #{chain}:#{contract}:#{method} - " <>
            "estimate #{gas_limit} exceeds #{Float.round(threshold, 1)}x average #{trunc(avg)}"
          )
        end
        {gas_limit, anomaly}

      _ ->
        {gas_limit, false}
    end
  end

  defp extract_method_id(nil), do: "unknown"
  defp extract_method_id("0x" <> hex) when byte_size(hex) >= 8, do: "0x" <> String.slice(hex, 0, 8)
  defp extract_method_id(data) when is_binary(data), do: data
  defp extract_method_id(_), do: "unknown"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_hex_int("0x" <> hex), do: String.to_integer(hex, 16)
  defp parse_hex_int(_), do: 0
end
