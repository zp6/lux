# Gas Optimization

Comprehensive gas optimization toolkit for EVM-compatible chains in Lux.

## Overview

The `Lux.Web3.GasOptimizer` module provides tools to minimize gas costs when interacting with EVM-compatible blockchains. It includes real-time gas monitoring, price prediction, transaction batching, and intelligent gas limit estimation.

## Supported Chains

| Chain     | Chain ID | EIP-1559 | RPC Endpoint                       |
|-----------|----------|----------|-------------------------------------|
| Ethereum  | 1        | ✅       | `https://eth.llamarpc.com`         |
| Polygon   | 137      | ✅       | `https://polygon-rpc.com`          |
| BSC       | 56       | ❌       | `https://bsc-dataseed.binance.org` |
| Arbitrum  | 42161    | ✅       | `https://arb1.arbitrum.io/rpc`     |

## Architecture

```
Lux.Web3.GasOptimizer (Main Module)
├── Estimator  - Gas limit estimation with historical tracking
├── Batcher    - Transaction batching for cost reduction
└── Predictor  - Gas price prediction and trend analysis
```

## Quick Start

### 1. Configuration

Add to your `config/runtime.exs`:

```elixir
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
```

### 2. Get Current Gas Prices

```elixir
alias Lux.Web3.GasOptimizer

# For EIP-1559 chains (Ethereum, Polygon, Arbitrum)
{:ok, prices} = GasOptimizer.get_gas_prices(:ethereum)
# => %{
#   base_fee: 15_000_000_000,
#   priority_fee: 1_500_000_000,
#   max_fee: 31_500_000_000,
#   chain: :ethereum
# }

# For legacy chains (BSC)
{:ok, prices} = GasOptimizer.get_gas_prices(:bsc)
# => %{gas_price: 3_000_000_000, chain: :bsc}
```

### 3. Get Suggested Gas Price

```elixir
# Speed options: :slow, :medium, :fast, :instant
{:ok, suggestion} = GasOptimizer.suggest_gas_price(:ethereum, :fast)
# => %{
#   base_fee: 15_000_000_000,
#   priority_fee: 2_250_000_000,
#   max_fee: 47_250_000_000,
#   max_priority_fee_per_gas: 2_250_000_000,
#   max_fee_per_gas: 47_250_000_000,
#   estimated_confirmation_seconds: 30,
#   chain: :ethereum,
#   speed: :fast
# }
```

### 4. Estimate Gas Limit

```elixir
alias Lux.Web3.GasOptimizer.Estimator

# Estimate via RPC simulation
{:ok, {gas_limit, meta}} = Estimator.estimate(:ethereum, %{
  to: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
  from: "0xSenderAddress",
  data: "0xa9059cbb000000000000000000000000..."
})

# Record actual usage for better future estimates
:ok = Estimator.record_usage(:ethereum, "0xdAC17F...", "transfer", gas_used)

# Check historical stats
{:ok, stats} = Estimator.get_history(:ethereum, "0xdAC17F...", "transfer")
# => %{avg: 55230.5, min: 51000, max: 65000, count: 20}
```

### 5. Batch Transactions

```elixir
alias Lux.Web3.GasOptimizer.Batcher

# Create a batch for ERC-20 transfers
{:ok, batch} = Batcher.new_batch(:ethereum, %{
  contract: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
  type: :erc20_transfer
})

# Add transfers
{:ok, batch} = Batcher.add_transfer(batch, %{to: "0xRecipient1", amount: 1000})
{:ok, batch} = Batcher.add_transfer(batch, %{to: "0xRecipient2", amount: 2000})

# Check savings
{:ok, savings} = Batcher.estimate_savings(batch)
# => %{individual_gas: 114_000, batch_gas: 46_000, saved_gas: 68_000, saved_percent: 59.6}

# Build the batch transaction data
{:ok, tx_data} = Batcher.build(batch)
```

### 6. Predict Optimal Timing

```elixir
alias Lux.Web3.GasOptimizer.Predictor

# Get comprehensive prediction
{:ok, prediction} = Predictor.predict(:ethereum)
# => %{
#   current_trend: :decreasing,
#   suggested_wait_seconds: 1800,
#   estimated_savings_percent: 15.5,
#   optimal_window: %{start: ~U[...], end: ~U[...]},
#   volatility: :low,
#   recommendation: :wait
# }

# Quick check
case Predictor.should_wait?(:ethereum) do
  {:ok, {:wait, seconds}} -> IO.puts("Wait #{seconds} seconds")
  {:ok, :send_now} -> IO.puts("Send now!")
end

# Detect low-traffic periods
{:ok, periods} = Predictor.detect_low_periods(:ethereum)
# => [%{start_hour: 0, end_hour: 6, avg_savings_percent: 25.0}]
```

## Module Reference

### `Lux.Web3.GasOptimizer`

Main module providing:
- `get_gas_prices/1` - Fetch current gas prices for a chain
- `suggest_gas_price/2` - Get optimal gas price suggestion by speed
- `estimate_gas/2` - Estimate gas limit for a transaction
- `predict_optimal_time/1` - Predict best time to send

### `Lux.Web3.GasOptimizer.Estimator`

Gas limit estimation with:
- RPC-based `eth_estimateGas` simulation
- Historical gas usage tracking (ETS-backed)
- Configurable safety margins (default 10%)
- Anomaly detection (flags estimates >2x historical average)

### `Lux.Web3.GasOptimizer.Batcher`

Transaction batching:
- ERC-20 transfer batching
- Gas savings estimation (up to 60% for 10+ transfers)
- Configurable batch size and gas limits
- Timeout-based auto-processing

### `Lux.Web3.GasOptimizer.Predictor`

Gas price prediction:
- Linear regression on recent base fees
- Trend detection (increasing/decreasing/stable)
- Volatility assessment
- Low-traffic period detection (UTC nighttime)
- Weekend bonus detection

## Performance Tips

1. **Use `:slow` speed for non-urgent transactions** — saves 20% on gas costs
2. **Batch ERC-20 transfers** — saves ~60% for 10+ transfers
3. **Send during off-peak hours** — typically UTC 00:00-06:00 for Ethereum
4. **Record actual gas usage** — improves future estimates via historical data
5. **Set `max_gas_price`** — prevents accidentally overpaying during gas spikes

## Error Handling

All functions return `{:ok, result}` or `{:error, reason}` tuples:

```elixir
case GasOptimizer.get_gas_prices(:ethereum) do
  {:ok, prices} ->
    # Use prices
    :ok

  {:error, {:gas_price_fetch_failed, :ethereum, reason}} ->
    # Handle RPC failure
    Logger.warning("Gas price fetch failed: #{inspect(reason)}")
end
```

## Testing

```bash
# Run gas optimizer tests
mix test test/unit/lux/web3/gas_optimizer_test.exs

# Run with verbose output
mix test test/unit/lux/web3/gas_optimizer_test.exs --trace
```

Tests use mocked RPC responses and don't require live chain connections.
