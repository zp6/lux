defmodule Lux.Integrations.NFT.Marketplace do
  @moduledoc """
  NFT marketplace data aggregator supporting OpenSea, Blur, and other platforms.

  Provides a unified interface for:
  - Collection statistics (floor price, volume, owners count)
  - Price tracking (historical prices, trend analysis)
  - Sales monitoring (latest成交记录)
  - Rarity calculation (trait-based rarity scoring)
  - Cross-marketplace comparison

  ## Configuration

      config :lux, :nft_marketplace,
        cache_ttl: 300,           # 5 minutes
        default_marketplace: :opensea

      config :lux, Lux.Integrations.NFT.OpenSea,
        api_key: System.get_env("OPENSEA_API_KEY")

      config :lux, Lux.Integrations.NFT.Blur,
        auth_token: System.get_env("BLUR_AUTH_TOKEN")

  ## Usage

      alias Lux.Integrations.NFT.Marketplace

      # Get aggregated collection stats
      {:ok, stats} = Marketplace.get_collection_stats("bored-ape-yacht-club")

      # Compare across marketplaces
      {:ok, comparison} = Marketplace.compare_marketplaces("bored-ape-yacht-club")

      # Get recent sales aggregated
      {:ok, sales} = Marketplace.get_recent_sales("bored-ape-yacht-club", limit: 10)

      # Calculate rarity for a collection
      {:ok, scored} = Marketplace.calculate_rarity(tokens)
  """

  require Logger

  alias Lux.Integrations.NFT.OpenSea
  alias Lux.Integrations.NFT.Blur
  alias Lux.Integrations.NFT.Rarity

  @type marketplace :: :opensea | :blur | :all
  @type collection_stats :: %{
    slug: String.t(),
    floor_price: float() | nil,
    total_volume: float(),
    owners_count: integer(),
    total_supply: integer(),
    one_day_volume: float(),
    seven_day_volume: float(),
    thirty_day_volume: float(),
    marketplaces: [map()]
  }

  @type sale_record :: %{
    token_id: String.t(),
    price: float(),
    currency: String.t(),
    seller: String.t(),
    buyer: String.t(),
    timestamp: String.t(),
    marketplace: String.t()
  }

  @type price_trend :: %{
    direction: :up | :down | :stable,
    change_percent: float(),
    period: String.t(),
    data_points: [map()]
  }

  # --- Collection Statistics ---

  @doc """
  Fetches aggregated collection statistics.

  By default fetches from OpenSea. Use `marketplace: :all` for cross-platform aggregation.

  ## Parameters

    * `slug` - Collection slug (OpenSea format) or contract address
    * `opts` - Options (marketplace: :opensea | :blur | :all)

  ## Examples

      {:ok, stats} = Marketplace.get_collection_stats("bored-ape-yacht-club")
      {:ok, stats} = Marketplace.get_collection_stats("0xBC4CA0Ed...", marketplace: :blur)
  """
  @spec get_collection_stats(String.t(), keyword()) :: {:ok, collection_stats()} | {:error, term()}
  def get_collection_stats(slug, opts \\ []) do
    marketplace = Keyword.get(opts, :marketplace, :opensea)

    case marketplace do
      :opensea ->
        fetch_opensea_stats(slug)

      :blur ->
        fetch_blur_stats(slug)

      :all ->
        aggregate_stats(slug)
    end
  end

  @doc """
  Compares collection data across marketplaces.

  Fetches stats from OpenSea and Blur, then merges into a comparison view.

  ## Examples

      {:ok, comparison} = Marketplace.compare_marketplaces("bored-ape-yacht-club")
      # => %{opensea: %{floor_price: 12.5, ...}, blur: %{floor_price: 12.3, ...}}
  """
  @spec compare_marketplaces(String.t()) :: {:ok, map()} | {:error, term()}
  def compare_marketplaces(slug) do
    tasks = [
      Task.Supervisor.async_nolink(Lux.TaskSupervisor, fn ->
        {:opensea, fetch_opensea_stats(slug)}
      end),
      Task.Supervisor.async_nolink(Lux.TaskSupervisor, fn ->
        {:blur, fetch_blur_stats(slug)}
      end)
    ]

    results =
      tasks
      |> Task.yield_many(:infinity)
      |> Enum.into(%{}, fn {task, result} ->
        Task.shutdown(task, :brutal_kill)
        case result do
          {:ok, {key, {:ok, stats}}} -> {key, stats}
          {:ok, {key, {:error, _}}} -> {key, nil}
          {:exit, _} -> {elem(task, 0), nil}
        end
      end)

    best_floor = best_floor_price(results)

    {:ok, %{
      slug: slug,
      marketplaces: results,
      best_floor_price: best_floor,
      compared_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }}
  end

  @doc """
  Fetches recent sales across marketplaces.

  Aggregates sales from OpenSea and Blur, sorted by timestamp (newest first).

  ## Parameters

    * `slug` - Collection slug
    * `opts` - Options (limit: integer, default 20)

  ## Examples

      {:ok, sales} = Marketplace.get_recent_sales("bored-ape-yacht-club", limit: 10)
  """
  @spec get_recent_sales(String.t(), keyword()) :: {:ok, [sale_record()]} | {:error, term()}
  def get_recent_sales(slug, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    opensea_task = Task.Supervisor.async_nolink(Lux.TaskSupervisor, fn ->
      case OpenSea.get_events(slug, type: "sale", limit: limit) do
        {:ok, events} -> Enum.map(events, &Map.put(&1, :marketplace, "opensea"))
        {:error, _} -> []
      end
    end)

    blur_task = Task.Supervisor.async_nolink(Lux.TaskSupervisor, fn ->
      case Blur.get_sales(slug, limit: limit) do
        {:ok, sales} -> Enum.map(sales, &Map.put(&1, :marketplace, "blur"))
        {:error, _} -> []
      end
    end)

    [opensea_task, blur_task]
    |> Task.yield_many(:infinity)
    |> Enum.flat_map(fn {task, result} ->
      Task.shutdown(task, :brutal_kill)
      case result do
        {:ok, sales} -> sales
        {:exit, _} -> []
      end
    end)
    |> Enum.sort_by(& &1.timestamp, :desc)
    |> Enum.take(limit)
    |> then(&{:ok, &1})
  end

  @doc """
  Analyzes price trends for a collection.

  Compares recent volume changes to determine trend direction.

  ## Parameters

    * `slug` - Collection slug
    * `opts` - Options (period: "1d" | "7d" | "30d", default "7d")

  ## Examples

      {:ok, trend} = Marketplace.analyze_price_trend("bored-ape-yacht-club", period: "7d")
      # => %{direction: :up, change_percent: 5.3, ...}
  """
  @spec analyze_price_trend(String.t(), keyword()) :: {:ok, price_trend()} | {:error, term()}
  def analyze_price_trend(slug, opts \\ []) do
    period = Keyword.get(opts, :period, "7d")

    with {:ok, stats} <- OpenSea.get_collection_stats(slug) do
      {current_key, previous_key} = period_keys(period)

      current = Map.get(stats, current_key, 0.0)
      previous = Map.get(stats, previous_key, 0.0)

      {direction, change} =
        cond do
          previous == 0.0 -> {:stable, 0.0}
          true ->
            pct = (current - previous) / abs(previous) * 100.0
            dir = cond do
              pct > 5.0 -> :up
              pct < -5.0 -> :down
              true -> :stable
            end
            {dir, Float.round(pct, 2)}
        end

      {:ok, %{
        direction: direction,
        change_percent: change,
        period: period,
        current_volume: current,
        previous_volume: previous,
        analyzed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }}
    end
  end

  @doc """
  Calculates rarity scores for a collection of tokens.

  Wraps `Lux.Integrations.NFT.Rarity.score_collection/2`.

  ## Parameters

    * `tokens` - List of maps with `:id` and `:traits` keys
    * `opts` - Options passed to Rarity module

  ## Examples

      {:ok, scored} = Marketplace.calculate_rarity(tokens)
      # => [%{id: 1, rarity_score: 85.3, rarity_rank: 1, normalized_score: 100.0}, ...]
  """
  @spec calculate_rarity([map()], keyword()) :: {:ok, [map()]}
  def calculate_rarity(tokens, opts \\ []) do
    Rarity.score_collection(tokens, opts)
  end

  # --- Private ---

  defp fetch_opensea_stats(slug) do
    case OpenSea.get_collection_stats(slug) do
      {:ok, stats} -> {:ok, %{stats | source: "opensea"}}
      error -> error
    end
  end

  defp fetch_blur_stats(address) do
    case Blur.get_collection_stats(address) do
      {:ok, stats} -> {:ok, %{stats | source: "blur"}}
      error -> error
    end
  end

  defp aggregate_stats(slug) do
    opensea_task = Task.Supervisor.async_nolink(Lux.TaskSupervisor, fn ->
      OpenSea.get_collection_stats(slug)
    end)

    blur_task = Task.Supervisor.async_nolink(Lux.TaskSupervisor, fn ->
      Blur.get_collection_stats(slug)
    end)

    results =
      [opensea_task, blur_task]
      |> Task.yield_many(:infinity)
      |> Enum.map(fn {task, result} ->
        Task.shutdown(task, :brutal_kill)
        result
      end)

    opensea_result = Enum.at(results, 0)
    blur_result = Enum.at(results, 1)

    merged = merge_marketplace_stats(slug, opensea_result, blur_result)
    {:ok, merged}
  end

  defp merge_marketplace_stats(slug, opensea_result, blur_result) do
    opensea_data = extract_data(opensea_result)
    blur_data = extract_data(blur_result)

    %{
      slug: slug,
      floor_price: min_of(opensea_data[:floor_price], blur_data[:floor_price]),
      total_volume: max_of(opensea_data[:total_volume], blur_data[:total_volume]),
      owners_count: max_of(opensea_data[:owners_count], blur_data[:owners_count]),
      total_supply: opensea_data[:total_supply] || blur_data[:total_supply] || 0,
      one_day_volume: opensea_data[:one_day_volume] || 0.0,
      seven_day_volume: opensea_data[:seven_day_volume] || 0.0,
      thirty_day_volume: opensea_data[:thirty_day_volume] || 0.0,
      sources: %{
        opensea: opensea_data,
        blur: blur_data
      },
      aggregated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp extract_data({:ok, {:ok, data}}), do: data
  defp extract_data(_), do: %{}

  defp min_of(a, b) when is_number(a) and is_number(b), do: min(a, b)
  defp min_of(a, nil) when is_number(a), do: a
  defp min_of(nil, b) when is_number(b), do: b
  defp min_of(_, _), do: nil

  defp max_of(a, b) when is_number(a) and is_number(b), do: max(a, b)
  defp max_of(a, nil) when is_number(a), do: a
  defp max_of(nil, b) when is_number(b), do: b
  defp max_of(_, _), do: nil

  defp period_keys("1d"), do: {:one_day_volume, :seven_day_volume}
  defp period_keys("7d"), do: {:seven_day_volume, :thirty_day_volume}
  defp period_keys("30d"), do: {:thirty_day_volume, :total_volume}
  defp period_keys(_), do: {:seven_day_volume, :thirty_day_volume}

  defp best_floor_price(results) do
    prices =
      results
      |> Map.values()
      |> Enum.filter(& &1)
      |> Enum.map(& &1[:floor_price])
      |> Enum.filter(&is_number/1)

    case prices do
      [] -> nil
      _ -> Enum.min(prices)
    end
  end
end
