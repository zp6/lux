# NFT Marketplace Data Aggregation

Integration module for aggregating NFT marketplace data across multiple platforms.

## Overview

This module provides a unified interface for accessing NFT collection data, sales events, price tracking, and rarity scoring from marketplaces like OpenSea and Blur.

## Modules

| Module | Description |
|--------|-------------|
| `Lux.Integrations.NFT.Marketplace` | Unified aggregator across marketplaces |
| `Lux.Integrations.NFT.OpenSea` | OpenSea API v2 integration |
| `Lux.Integrations.NFT.Blur` | Blur marketplace integration |
| `Lux.Integrations.NFT.Rarity` | Trait-based rarity scoring engine |

## Configuration

Add to your `config/runtime.exs`:

```elixir
config :lux, Lux.Integrations.NFT.OpenSea,
  api_key: System.get_env("OPENSEA_API_KEY"),
  base_url: "https://api.opensea.io"

config :lux, Lux.Integrations.NFT.Blur,
  auth_token: System.get_env("BLUR_AUTH_TOKEN"),
  base_url: "https://api.blur.io"
```

Set environment variables:

```bash
OPENSEA_API_KEY="your-opensea-api-key"
BLUR_AUTH_TOKEN="your-blur-auth-token"
```

## Usage Examples

### Collection Statistics

```elixir
alias Lux.Integrations.NFT.Marketplace

# Get stats from a single marketplace
{:ok, stats} = Marketplace.get_collection_stats("bored-ape-yacht-club")
# => %{slug: "bored-ape-yacht-club", floor_price: 12.5, total_volume: 650000.0, ...}

# Aggregate across all marketplaces
{:ok, stats} = Marketplace.get_collection_stats("bored-ape-yacht-club", marketplace: :all)
# => Merges data from OpenSea and Blur, picks best floor price
```

### Cross-Marketplace Comparison

```elixir
{:ok, comparison} = Marketplace.compare_marketplaces("bored-ape-yacht-club")
# => %{
#   slug: "bored-ape-yacht-club",
#   marketplaces: %{
#     opensea: %{floor_price: 12.5, ...},
#     blur: %{floor_price: 12.3, ...}
#   },
#   best_floor_price: 12.3
# }
```

### Recent Sales

```elixir
{:ok, sales} = Marketplace.get_recent_sales("bored-ape-yacht-club", limit: 10)
# => [
#   %{token_id: "1234", price: 13.2, marketplace: "opensea", ...},
#   %{token_id: "5678", price: 12.8, marketplace: "blur", ...},
#   ...
# ]
```

### Price Trend Analysis

```elixir
{:ok, trend} = Marketplace.analyze_price_trend("bored-ape-yacht-club", period: "7d")
# => %{direction: :up, change_percent: 5.3, period: "7d"}
```

### Rarity Scoring

```elixir
# Define tokens with traits
tokens = [
  %{id: 1, traits: %{"Background" => "Cosmic", "Eyes" => "Laser", "Hat" => "Crown"}},
  %{id: 2, traits: %{"Background" => "Blue", "Eyes" => "Normal", "Hat" => "None"}},
  %{id: 3, traits: %{"Background" => "Blue", "Eyes" => "Normal", "Hat" => "Cap"}},
  # ... more tokens
]

{:ok, scored} = Marketplace.calculate_rarity(tokens)
# => [
#   %{id: 1, rarity_score: 85.3, rarity_rank: 1, normalized_score: 100.0},
#   %{id: 3, rarity_score: 42.1, rarity_rank: 2, normalized_score: 50.0},
#   %{id: 2, rarity_score: 42.1, rarity_rank: 3, normalized_score: 50.0},
# ]
```

### Direct API Access

#### OpenSea

```elixir
alias Lux.Integrations.NFT.OpenSea

# Get collection data
{:ok, collection} = OpenSea.get_collection("bored-ape-yacht-club")

# Get active listings
{:ok, listings} = OpenSea.get_listings("bored-ape-yacht-club", limit: 10)

# Get sales events
{:ok, events} = OpenSea.get_events("bored-ape-yacht-club", type: "sale", limit: 20)

# Get collection stats
{:ok, stats} = OpenSea.get_collection_stats("bored-ape-yacht-club")
```

#### Blur

```elixir
alias Lux.Integrations.NFT.Blur

# Get collection data (by contract address)
{:ok, collection} = Blur.get_collection("0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D")

# Get price history
{:ok, prices} = Blur.get_price_history("0xBC4CA0Ed...", period: "7d")

# Get recent sales
{:ok, sales} = Blur.get_sales("0xBC4CA0Ed...", limit: 10)
```

#### Rarity Engine

```elixir
alias Lux.Integrations.NFT.Rarity

# Build trait distribution
distribution = Rarity.build_trait_distribution(tokens)
# => %{"Background" => %{"Blue" => 500, "Cosmic" => 10}, ...}

# Single trait rarity
Rarity.single_trait_rarity("Background", "Cosmic", distribution, 10000)
# => 1000.0 (1% occurrence = very rare)

# Jaccard similarity between two tokens
Rarity.jaccard_similarity(token_a.traits, token_b.traits)
# => 0.33

# Find similar tokens
similar = Rarity.find_similar(reference_token, all_tokens, limit: 5)

# Build similarity matrix
matrix = Rarity.jaccard_matrix(tokens)
# => %{{1, 2} => 0.33, {1, 3} => 0.5, ...}
```

## Architecture

```
Marketplace (Aggregator)
├── OpenSea (API Client)
├── Blur (API Client)
└── Rarity (Scoring Engine)
```

- **Marketplace** provides the unified API, handles cross-platform aggregation and parallel fetching
- **OpenSea/Blur** are HTTP clients with response parsing and error handling
- **Rarity** is a pure calculation engine (no external API calls)

## Error Handling

All API functions return `{:ok, result}` or `{:error, reason}`.

Common error reasons:
- `:rate_limited` - API rate limit hit
- `:unauthorized` - Missing or invalid API key
- `:not_found` - Collection not found
- `{:status_code, body}` - Unexpected API error

## Testing

```bash
# Run all NFT integration tests
mix test test/integration/nft_test.exs

# Run only rarity tests (no API key needed)
mix test test/integration/nft_test.exs --include nft

# Run with tag filter
mix test --include nft
```

## Rate Limiting

- OpenSea: ~5 requests/second (varies by plan)
- Blur: ~2 requests/second

Consider using caching for frequently accessed data. The aggregator parallelizes cross-marketplace requests to minimize latency.
