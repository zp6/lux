defmodule Lux.Prisms.Twitter.Automation.ContentCurator do
  @moduledoc """
  A prism for content curation — discovering, filtering, and organizing tweet-worthy
  content from various sources for scheduled or immediate posting.

  ## Examples

      iex> ContentCurator.handler(%{
      ...>   action: "curate",
      ...>   topics: ["AI", "blockchain"],
      ...>   max_items: 5
      ...> }, %{name: "Agent"})
      {:ok, %{items: [...], total: 5}}
  """

  use Lux.Prism,
    name: "Twitter Content Curator",
    description: "Discovers and curates content for tweet scheduling and engagement",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: curate, add_source, remove_source, list_sources",
          enum: ["curate", "add_source", "remove_source", "list_sources"]
        },
        topics: %{
          type: :array,
          items: %{type: :string},
          description: "Topics to curate content for"
        },
        max_items: %{
          type: :integer,
          description: "Maximum number of curated items to return (default: 10)"
        },
        source: %{
          type: :object,
          properties: %{
            name: %{type: :string},
            type: %{type: :string, enum: ["rss", "api", "hashtag", "user_timeline"]},
            url: %{type: :string},
            refresh_interval_minutes: %{type: :integer}
          }
        },
        source_id: %{
          type: :string,
          description: "Source ID for remove_source action"
        },
        content_filters: %{
          type: :object,
          properties: %{
            min_engagement: %{type: :integer},
            exclude_keywords: %{type: :array, items: %{type: :string}},
            language: %{type: :string},
            date_range_days: %{type: :integer}
          }
        }
      },
      required: ["action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        items: %{type: :array},
        total: %{type: :integer},
        sources: %{type: :array}
      }
    }

  require Logger

  @sources_table :lux_content_sources

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    ensure_sources_table()

    case params[:action] do
      "curate" -> curate_content(params, agent_name)
      "add_source" -> add_source(params, agent_name)
      "remove_source" -> remove_source(params)
      "list_sources" -> list_sources()
      _ -> {:error, "Unknown action: #{params[:action]}"}
    end
  end

  defp curate_content(params, agent_name) do
    topics = params[:topics] || []
    max_items = params[:max_items] || 10
    filters = params[:content_filters] || %{}

    Logger.info("Agent #{agent_name} curating content for topics: #{inspect(topics)}")

    sources = get_all_sources()

    items =
      sources
      |> Enum.flat_map(&fetch_from_source(&1, topics, filters))
      |> apply_filters(filters)
      |> Enum.sort_by(& &1.engagement_score, :desc)
      |> Enum.take(max_items)
      |> Enum.map(&format_curated_item/1)

    {:ok, %{items: items, total: length(items)}}
  end

  defp add_source(params, agent_name) do
    source = params[:source]
    case validate_source(source) do
      {:ok, validated} ->
        source_id = "src_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

        entry = Map.merge(validated, %{
          id: source_id,
          added_by: agent_name,
          added_at: DateTime.utc_now(),
          refresh_interval_minutes: source[:refresh_interval_minutes] || 60
        })

        current = get_all_sources()
        :ets.insert(@sources_table, {:sources, [entry | current]})

        {:ok, %{source_id: source_id, status: "added"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_source(params) do
    case params[:source_id] do
      nil -> {:error, "Missing source_id"}
      id ->
        current = get_all_sources()
        filtered = Enum.reject(current, &(&1.id == id))
        :ets.insert(@sources_table, {:sources, filtered})
        {:ok, %{source_id: id, status: "removed"}}
    end
  end

  defp list_sources do
    {:ok, %{sources: get_all_sources()}}
  end

  defp fetch_from_source(source, topics, _filters) do
    topic_keywords = if topics == [], do: true, else: false

    # Simulate content fetch based on source type
    case source.type do
      "hashtag" ->
        Enum.map(topics, fn topic ->
          %{
            title: "Trending: ##{topic}",
            body: "Latest discussions around ##{topic}",
            source: source.name,
            source_type: "hashtag",
            url: "https://twitter.com/search?q=%23#{topic}",
            engagement_score: :rand.uniform(100),
            published_at: DateTime.utc_now(),
            topics: [topic]
          }
        end)

      "user_timeline" ->
        if topic_keywords do
          [%{
            title: "Update from #{source.name}",
            body: "Latest post from #{source.name}",
            source: source.name,
            source_type: "user_timeline",
            url: source.url || "",
            engagement_score: :rand.uniform(80),
            published_at: DateTime.utc_now(),
            topics: []
          }]
        else
          []
        end

      _ ->
        []
    end
  end

  defp apply_filters(items, filters) do
    items
    |> maybe_filter_engagement(filters[:min_engagement])
    |> maybe_exclude_keywords(filters[:exclude_keywords])
    |> maybe_filter_language(filters[:language])
    |> maybe_filter_date_range(filters[:date_range_days])
  end

  defp maybe_filter_engagement(items, nil), do: items
  defp maybe_filter_engagement(items, min), do: Enum.filter(items, &(&1.engagement_score >= min))

  defp maybe_exclude_keywords(items, nil), do: items
  defp maybe_exclude_keywords(items, keywords) do
    Enum.filter(items, fn item ->
      text = String.downcase("#{item.title} #{item.body}")
      not Enum.any?(keywords, &String.contains?(text, String.downcase(&1)))
    end)
  end

  defp maybe_filter_language(items, nil), do: items
  defp maybe_filter_language(items, _lang), do: items

  defp maybe_filter_date_range(items, nil), do: items
  defp maybe_filter_date_range(items, days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86400, :second)
    Enum.filter(items, &(DateTime.compare(&1.published_at, cutoff) in [:gt, :eq]))
  end

  defp format_curated_item(item) do
    %{
      title: item.title,
      body: item.body,
      source: item.source,
      url: item.url,
      engagement_score: item.engagement_score,
      suggested_tweet: generate_tweet_suggestion(item),
      published_at: DateTime.to_iso8601(item.published_at)
    }
  end

  defp generate_tweet_suggestion(item) do
    "#{item.title} — #{String.slice(item.body, 0, 200)}"
    |> String.slice(0, 280)
  end

  defp validate_source(nil), do: {:error, "Missing source parameter"}
  defp validate_source(source) do
    cond do
      is_nil(source[:name]) or source[:name] == "" -> {:error, "Source name is required"}
      is_nil(source[:type]) -> {:error, "Source type is required"}
      source[:type] not in ["rss", "api", "hashtag", "user_timeline"] -> {:error, "Invalid source type"}
      true -> {:ok, source}
    end
  end

  defp get_all_sources do
    case :ets.lookup(@sources_table, :sources) do
      [{:sources, sources}] -> sources
      [] -> []
    end
  end

  defp ensure_sources_table do
    case :ets.whereis(@sources_table) do
      :undefined -> :ets.new(@sources_table, [:named_table, :public, :set])
      _ -> :ok
    end
  end
end
