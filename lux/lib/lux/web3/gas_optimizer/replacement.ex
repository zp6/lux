defmodule Lux.Web3.GasOptimizer.Replacement do
  @moduledoc """
  Transaction replacement helpers for fee bumping.

  Provides same-nonce replacement strategies for EIP-1559 and legacy
  transactions. When a transaction is stuck, use these helpers to create
  a replacement transaction with higher fees while preserving the original nonce.

  ## Replacement Rules

  - EIP-1559: The replacement's `max_fee_per_gas` must be at least 10% higher
    than the original's, and `max_priority_fee_per_gas` must be at least
    the original's value.
  - Legacy: The replacement's `gas_price` must be at least 10% higher than
    the original's.
  - The nonce, to, from, value, and data fields must remain identical.

  ## Usage

      alias Lux.Web3.GasOptimizer.Replacement

      original_tx = %{
        nonce: 5,
        to: "0xRecipient",
        from: "0xSender",
        value: 1_000_000_000_000_000_000,
        data: "0xabcdef",
        max_fee_per_gas: 30_000_000_000,
        max_priority_fee_per_gas: 2_000_000_000,
        gas_limit: 65_000
      }

      {:ok, replacement} = Replacement.bump_fees(original_tx, :eip1559)
      assert replacement.nonce == 5
      assert replacement.max_fee_per_gas > original_tx.max_fee_per_gas
  """

  @type tx :: map()
  @type tx_type :: :eip1559 | :legacy

  # Minimum fee bump percentage required by Ethereum network (10%)
  @min_bump_percent 10

  # Maximum number of replacement attempts to prevent runaway fee escalation
  @max_replacement_attempts 5

  @doc """
  Bumps fees on a transaction to create a valid replacement.

  Increases the gas fees by at least the minimum required percentage (10% by default).
  The replacement preserves the original nonce, to, from, value, and data.

  ## Parameters

    * `tx` - The original transaction map
    * `tx_type` - `:eip1559` or `:legacy`
    * `opts` - Options:
      * `:percent` - Bump percentage (default: 10, minimum: 10)
      * `:max_fee_cap` - Maximum allowed fee in wei (default: 500 Gwei)

  ## Returns

    * `{:ok, replacement_tx}` - New transaction with bumped fees
    * `{:error, reason}` - Bump failed
  """
  @spec bump_fees(tx(), tx_type(), keyword()) :: {:ok, tx()} | {:error, term()}
  def bump_fees(tx, tx_type, opts \\ []) do
    bump_percent = Keyword.get(opts, :percent, @min_bump_percent)
    max_fee_cap = Keyword.get(opts, :max_fee_cap, 500_000_000_000)

    cond do
      bump_percent < @min_bump_percent ->
        {:error, {:invalid_bump_percent, bump_percent,
         "Must be at least #{@min_bump_percent}%"}}

      tx_type == :eip1559 ->
        bump_eip1559(tx, bump_percent, max_fee_cap)

      tx_type == :legacy ->
        bump_legacy(tx, bump_percent, max_fee_cap)

      true ->
        {:error, {:unknown_tx_type, tx_type}}
    end
  end

  @doc """
  Validates that a replacement transaction is acceptable by network rules.

  Checks that nonce, to, from, value, data match and fees are sufficiently increased.

  ## Returns

    * `true` if valid
    * `{false, reason}` if invalid
  """
  @spec replaceable?(tx(), tx()) :: boolean() | {false, String.t()}
  def replaceable?(original, replacement) do
    cond do
      original[:nonce] != replacement[:nonce] ->
        {false, "nonce mismatch"}

      original[:to] != replacement[:to] ->
        {false, "recipient mismatch"}

      original[:from] != replacement[:from] ->
        {false, "sender mismatch"}

      original[:value] != replacement[:value] ->
        {false, "value mismatch"}

      original[:data] != replacement[:data] ->
        {false, "data mismatch"}

      original[:gas_limit] != nil and replacement[:gas_limit] != nil and
      replacement[:gas_limit] < original[:gas_limit] ->
        {false, "gas_limit decreased"}

      not fees_increased?(original, replacement) ->
        {false, "fees not increased sufficiently"}

      true ->
        true
    end
  end

  @doc """
  Builds a chain of replacement transactions with incrementally higher fees.

  ## Parameters

    * `original_tx` - The original transaction
    * `tx_type` - `:eip1559` or `:legacy`
    * `opts` - Options:
      * `:count` - Number of replacements (default: 3, max: #{@max_replacement_attempts})
      * `:step_percent` - Fee increase per step (default: 15)
      * `:max_fee_cap` - Maximum fee cap

  ## Returns

    * `{:ok, [replacement_1, replacement_2, ...]}`
    * `{:error, reason}`
  """
  @spec build_replacement_chain(tx(), tx_type(), keyword()) :: {:ok, [tx()]} | {:error, term()}
  def build_replacement_chain(original_tx, tx_type, opts \\ []) do
    count = Keyword.get(opts, :count, 3)
    step_percent = Keyword.get(opts, :step_percent, 15)

    if count > @max_replacement_attempts do
      {:error, {:too_many_replacements, count, "Max is #{@max_replacement_attempts}"}}
    else
      chain =
        1..count
        |> Enum.map(fn n ->
          percent = step_percent * n
          case bump_fees(original_tx, tx_type, percent: percent) do
            {:ok, bumped} -> bumped
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, chain}
    end
  end

  @doc """
  Calculates the minimum fee bump required for a valid replacement.

  Returns the minimum fee that would be accepted as a replacement (10% bump + 1 wei).

  ## Examples

      iex> Replacement.minimum_bump_fee(30_000_000_000, :eip1559)
      33_000_000_001
  """
  @spec minimum_bump_fee(non_neg_integer(), tx_type()) :: non_neg_integer()
  def minimum_bump_fee(original_fee, _tx_type) do
    trunc(original_fee * (1 + @min_bump_percent / 100)) + 1
  end

  # --- Private ---

  defp bump_eip1559(tx, bump_percent, max_fee_cap) do
    max_fee = Map.get(tx, :max_fee_per_gas) || Map.get(tx, :maxFeePerGas) || 0
    priority_fee = Map.get(tx, :max_priority_fee_per_gas) || Map.get(tx, :maxPriorityFeePerGas) || 0

    if max_fee == 0 do
      {:error, :missing_fee_fields}
    else
      new_max_fee = min(trunc(max_fee * (1 + bump_percent / 100)) + 1, max_fee_cap)
      new_priority_fee = min(trunc(priority_fee * (1 + bump_percent / 100)) + 1, new_max_fee)

      if new_max_fee >= max_fee_cap and max_fee >= max_fee_cap do
        {:error, :fee_cap_reached}
      else
        replacement =
          tx
          |> Map.put(:max_fee_per_gas, new_max_fee)
          |> Map.put(:max_priority_fee_per_gas, new_priority_fee)
          |> Map.delete(:maxFeePerGas)
          |> Map.delete(:maxPriorityFeePerGas)

        {:ok, replacement}
      end
    end
  end

  defp bump_legacy(tx, bump_percent, max_fee_cap) do
    gas_price = Map.get(tx, :gas_price) || 0

    if gas_price == 0 do
      {:error, :missing_gas_price}
    else
      new_gas_price = min(trunc(gas_price * (1 + bump_percent / 100)) + 1, max_fee_cap)

      if new_gas_price >= max_fee_cap and gas_price >= max_fee_cap do
        {:error, :fee_cap_reached}
      else
        {:ok, Map.put(tx, :gas_price, new_gas_price)}
      end
    end
  end

  defp fees_increased?(original, replacement) do
    orig_max_fee = Map.get(original, :max_fee_per_gas) || Map.get(original, :maxFeePerGas) || 0
    repl_max_fee = Map.get(replacement, :max_fee_per_gas) || Map.get(replacement, :maxFeePerGas) || 0

    if orig_max_fee > 0 and repl_max_fee > 0 do
      repl_max_fee >= minimum_bump_fee(orig_max_fee, :eip1559)
    else
      orig_gas_price = Map.get(original, :gas_price) || 0
      repl_gas_price = Map.get(replacement, :gas_price) || 0

      if orig_gas_price > 0 and repl_gas_price > 0 do
        repl_gas_price >= minimum_bump_fee(orig_gas_price, :legacy)
      else
        false
      end
    end
  end
end
