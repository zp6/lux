defmodule Lux.Web3.GasOptimizer.Batcher do
  @moduledoc """
  Transaction batcher for reducing gas costs through aggregation.

  Combines multiple transactions into a single batch to reduce per-transaction
  overhead. Particularly effective for ERC-20 transfers and similar repetitive
  operations.

  ## How Batching Reduces Gas

  Each Ethereum transaction has a fixed base cost of 21,000 gas. By batching
  N transfers into one transaction, you save `(N - 1) * 21,000` gas in base costs.
  For 10 transfers, that's 189,000 gas saved (~63% reduction at standard transfer cost).

  ## Configuration

      config :lux, Lux.Web3.GasOptimizer.Batcher,
        # Maximum number of transactions per batch
        max_batch_size: 100,
        # Maximum total gas limit per batch
        max_batch_gas_limit: 5_000_000,
        # Minimum number of transactions before batching kicks in
        min_batch_size: 2,
        # Maximum wait time in ms before processing a partial batch
        batch_timeout_ms: 30_000

  ## Usage

      alias Lux.Web3.GasOptimizer.Batcher

      # Create a batch for ERC-20 transfers
      {:ok, batch} = Batcher.new_batch(:ethereum, %{
        contract: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
        type: :erc20_transfer
      })

      # Add transfers to the batch
      {:ok, batch} = Batcher.add_transfer(batch, %{
        to: "0xRecipient1",
        amount: 1000
      })

      {:ok, batch} = Batcher.add_transfer(batch, %{
        to: "0xRecipient2",
        amount: 2000
      })

      # Build the batch transaction data
      {:ok, tx_data} = Batcher.build(batch)

      # Estimate savings
      {:ok, savings} = Batcher.estimate_savings(batch)
      # => %{individual_gas: 630_000, batch_gas: 245_000, saved_gas: 385_000, saved_percent: 61.1}
  """

  require Logger

  @type batch :: %{
          chain: atom(),
          contract: String.t() | nil,
          type: :erc20_transfer | :generic,
          transfers: [map()],
          created_at: integer()
        }

  @type savings :: %{
          individual_gas: non_neg_integer(),
          batch_gas: non_neg_integer(),
          saved_gas: non_neg_integer(),
          saved_percent: float()
        }

  # ERC-20 transfer selector: transfer(address,uint256)
  @erc20_transfer_selector "0xa9059cbb"

  @doc """
  Creates a new empty batch.

  ## Parameters

    * `chain` - Target chain atom
    * `opts` - Options including `:contract` address and `:type` (default: `:generic`)

  ## Examples

      {:ok, batch} = Batcher.new_batch(:ethereum, %{contract: "0x...", type: :erc20_transfer})
  """
  @spec new_batch(atom(), map()) :: {:ok, batch()}
  def new_batch(chain, opts \\ %{}) do
    {:ok, %{
      chain: chain,
      contract: Map.get(opts, :contract),
      type: Map.get(opts, :type, :generic),
      transfers: [],
      created_at: System.system_time(:millisecond)
    }}
  end

  @doc """
  Adds a transfer to the batch.

  ## Parameters

    * `batch` - The current batch
    * `transfer` - Map with `:to` address and `:amount` value

  ## Returns

    * `{:ok, updated_batch}` - Transfer added successfully
    * `{:error, :batch_full}` - Batch has reached maximum size
    * `{:error, :gas_limit_exceeded}` - Batch would exceed gas limit

  ## Examples

      {:ok, batch} = Batcher.add_transfer(batch, %{to: "0x...", amount: 1000})
  """
  @spec add_transfer(batch(), map()) :: {:ok, batch()} | {:error, term()}
  def add_transfer(batch, transfer) do
    max_size = max_batch_size()
    max_gas = max_batch_gas_limit()

    if length(batch.transfers) >= max_size do
      {:error, :batch_full}
    else
      new_transfers = batch.transfers ++ [transfer]

      # Estimate if batch would exceed gas limit
      estimated_gas = estimate_batch_gas(new_transfers, batch.type)

      if estimated_gas > max_gas do
        {:error, :gas_limit_exceeded}
      else
        {:ok, %{batch | transfers: new_transfers}}
      end
    end
  end

  @doc """
  Builds the encoded transaction data for the batch.

  For ERC-20 transfers, encodes each transfer as a separate call data
  segment that can be dispatched by a batch-aware contract.

  For generic batches, concatenates all transaction data.

  ## Examples

      {:ok, tx_data} = Batcher.build(batch)
      # => "0xa9059cbb000000000000000000000000..."
  """
  @spec build(batch()) :: {:ok, String.t()} | {:error, term()}
  def build(batch) do
    case batch.transfers do
      [] ->
        {:error, :empty_batch}

      transfers ->
        encoded =
          case batch.type do
            :erc20_transfer ->
              encode_erc20_batch(transfers)

            :generic ->
              encode_generic_batch(transfers)
          end

        {:ok, encoded}
    end
  end

  @doc """
  Estimates gas savings from batching vs individual transactions.

  ## Examples

      {:ok, savings} = Batcher.estimate_savings(batch)
      # => %{individual_gas: 630_000, batch_gas: 245_000, saved_gas: 385_000, saved_percent: 61.1}
  """
  @spec estimate_savings(batch()) :: {:ok, savings()}
  def estimate_savings(batch) do
    count = length(batch.transfers)

    individual_gas = estimate_individual_gas(count, batch.type)
    batch_gas = estimate_batch_gas(batch.transfers, batch.type)
    saved_gas = individual_gas - batch_gas
    saved_percent = if individual_gas > 0, do: Float.round(saved_gas / individual_gas * 100, 1), else: 0.0

    {:ok, %{
      individual_gas: individual_gas,
      batch_gas: batch_gas,
      saved_gas: saved_gas,
      saved_percent: saved_percent
    }}
  end

  @doc """
  Returns the number of transfers in the batch.
  """
  @spec batch_size(batch()) :: non_neg_integer()
  def batch_size(batch), do: length(batch.transfers)

  @doc """
  Checks if the batch has enough transactions to be worthwhile.

  A batch is considered worthwhile if it has at least `min_batch_size` transfers.
  """
  @spec worth_batching?(batch()) :: boolean()
  def worth_batching?(batch) do
    length(batch.transfers) >= min_batch_size()
  end

  @doc """
  Checks if the batch is full and ready to be processed.
  """
  @spec full?(batch()) :: boolean()
  def full?(batch) do
    length(batch.transfers) >= max_batch_size()
  end

  @doc """
  Checks if the batch has timed out and should be processed.
  """
  @spec timed_out?(batch()) :: boolean()
  def timed_out?(batch) do
    timeout = batch_timeout_ms()
    System.system_time(:millisecond) - batch.created_at > timeout
  end

  # --- Configuration ---

  @spec max_batch_size() :: pos_integer()
  defp max_batch_size do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_batch_size, 100)
  end

  @spec max_batch_gas_limit() :: pos_integer()
  defp max_batch_gas_limit do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_gas_limit, 5_000_000)
  end

  @spec min_batch_size() :: pos_integer()
  defp min_batch_size do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:min_batch_size, 2)
  end

  @spec batch_timeout_ms() :: pos_integer()
  defp batch_timeout_ms do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:batch_timeout_ms, 30_000)
  end

  # --- Gas Estimation ---

  # Individual: 21,000 base + ~36,000 per ERC-20 transfer
  defp estimate_individual_gas(count, :erc20_transfer) do
    count * (21_000 + 36_000)
  end

  # Individual: 21,000 base + ~25,000 per generic call
  defp estimate_individual_gas(count, :generic) do
    count * (21_000 + 25_000)
  end

  # Batch: 21,000 base + ~36,000 for first + ~25,000 per additional ERC-20 transfer
  defp estimate_batch_gas(transfers, :erc20_transfer) do
    count = length(transfers)
    21_000 + 36_000 + (count - 1) * 25_000
  end

  # Batch: 21,000 base + ~25,000 per call (minimal savings for generic)
  defp estimate_batch_gas(transfers, :generic) do
    21_000 + length(transfers) * 25_000
  end

  # --- Encoding ---

  defp encode_erc20_batch(transfers) do
    # For now, encode the first transfer as a standard ERC-20 transfer call.
    # In production, this would use a batch-aware contract (e.g., Multisend).
    # Each transfer is: transfer(address,uint256)
    transfers
    |> Enum.map(fn %{to: to, amount: amount} ->
      padded_to = String.downcase(to) |> String.replace_prefix("0x", "") |> String.pad_leading(64, "0")
      padded_amount = Integer.to_string(amount, 16) |> String.downcase() |> String.pad_leading(64, "0")
      @erc20_transfer_selector <> padded_to <> padded_amount
    end)
    |> Enum.join()
  end

  defp encode_generic_batch(transfers) do
    transfers
    |> Enum.map(fn transfer ->
      Map.get(transfer, :data, "")
    end)
    |> Enum.join()
  end
end
