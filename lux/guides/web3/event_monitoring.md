# Event Monitoring

Smart contract event monitoring system for EVM-compatible chains.

## Overview

The Event Monitor provides real-time tracking of smart contract events with subscription management, event decoding, persistent storage, and configurable alerts.

## Quick Start

```elixir
# Start monitoring a contract
{:ok, monitor} = EventMonitor.start_link(chain: :ethereum)

# Subscribe to Transfer events
Subscriber.subscribe(
  contract: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
  event: "Transfer",
  from_block: 18_000_000
)

# Check stored events
{:ok, events} = Storage.query(contract: "0xdAC...", event: "Transfer", limit: 50)

# Set up alerts for large transfers
Alerts.create_rule(
  name: "large_transfer",
  event: "Transfer",
  condition: fn event ->
    value = Decimal.new(event.params["value"])
    Decimal.compare(value, Decimal.new(1_000_000)) == :gt
  end,
  action: {:notify, :discord, channel: "security-alerts"}
)
```

## Module Reference

### EventMonitor

Main supervisor managing all event monitoring processes.

```elixir
# Supported chains
:ethereum, :polygon, :bsc, :arbitrum

# Start with custom config
EventMonitor.start_link(
  chain: :ethereum,
  rpc_url: "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY",
  poll_interval: 1_000  # 1 second
)
```

### Subscriber

Subscribe to contract events with filtering.

```elixir
# Basic subscription
Subscriber.subscribe(contract: address, event: "Transfer")

# With indexed parameter filters
Subscriber.subscribe(
  contract: address,
  event: "Transfer",
  filters: %{from: "0x..."}  # indexed parameter
)

# Historical replay from specific block
Subscriber.subscribe(
  contract: address,
  event: "Transfer",
  from_block: 17_000_000
)
```

### Decoder

ABI-based event log decoding.

```elixir
# Decode a raw log
{:ok, decoded} = Decoder.decode_log(log, abi: contract_abi)

# Auto-detect standard events (ERC-20, ERC-721, ERC-1155)
{:ok, decoded} = Decoder.decode_log(log)  # uses built-in signatures
```

### Storage

Persistent event storage with querying.

```elixir
# Query events
{:ok, events} = Storage.query(
  contract: address,
  event: "Transfer",
  from: ~U[2024-01-01 00:00:00Z],
  to: ~U[2024-01-31 23:59:59Z],
  limit: 100
)

# Get latest events
{:ok, events} = Storage.latest(limit: 20)
```

### Alerts

Rule-based event alerting system.

```elixir
# Threshold alert
Alerts.create_rule(
  name: "whale_alert",
  event: "Transfer",
  threshold: {:value, 1_000_000},
  action: {:notify, :telegram, chat: @chat_id}
)

# Custom condition
Alerts.create_rule(
  name: "custom",
  condition: fn event -> event.params["to"] == @target end,
  action: {:webhook, "https://hooks.slack.com/..."}
)
```

## Configuration

```elixir
config :lux, Lux.Web3.EventMonitor,
  chains: [
    ethereum: [rpc_url: "https://eth-mainnet.g.alchemy.com/v2/KEY"],
    polygon: [rpc_url: "https://polygon-rpc.com"],
    bsc: [rpc_url: "https://bsc-dataseed.binance.org"],
    arbitrum: [rpc_url: "https://arb1.arbitrum.io/rpc"]
  ],
  default_poll_interval: 2_000,
  max_reconnects: 10,
  storage: :ets  # or :postgres for production
```

## Performance Tips

- Use `from_block` to avoid scanning entire chain history
- Filter by indexed parameters to reduce event volume
- Set appropriate `poll_interval` per chain (faster = more RPC calls)
- Use `:postgres` storage for high-volume production workloads
- Batch webhook alerts to avoid rate limiting
