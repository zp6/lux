defmodule Lux.Prisms.Twitter.Automation.ScheduleTweet do
  @moduledoc """
  A prism for scheduling tweets to be posted at a specified future time.

  Supports scheduling individual tweets or tweet threads with configurable
  delivery times, timezone awareness, and queue management.

  ## Examples

      iex> ScheduleTweet.handler(%{
      ...>   text: "Hello from Lux!",
      ...>   scheduled_at: "2025-03-01T10:00:00Z"
      ...> }, %{name: "Agent"})
      {:ok, %{scheduled: true, tweet_id: "abc123", scheduled_at: "..."}}
  """

  use Lux.Prism,
    name: "Schedule Tweet",
    description: "Schedules a tweet for future posting at a specified time",
    input_schema: %{
      type: :object,
      properties: %{
        text: %{
          type: :string,
          description: "Text content of the tweet (max 280 characters)"
        },
        scheduled_at: %{
          type: :string,
          description: "ISO 8601 datetime string for when to post the tweet"
        },
        media_ids: %{
          type: :array,
          items: %{type: :string},
          description: "List of media IDs to attach to the tweet"
        },
        reply_settings: %{
          type: :string,
          description: "Who can reply: mentioned_users, following, or everyone",
          enum: ["mentioned_users", "following", "everyone"]
        },
        queue_name: %{
          type: :string,
          description: "Name of the scheduling queue (default: 'default')"
        },
        timezone: %{
          type: :string,
          description: "IANA timezone for the scheduled_at value (default: UTC)"
        }
      },
      required: ["text", "scheduled_at"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        scheduled: %{type: :boolean},
        tweet_id: %{type: :string},
        scheduled_at: %{type: :string},
        queue_position: %{type: :integer}
      },
      required: ["scheduled", "tweet_id", "scheduled_at"]
    }

  require Logger

  @queue_table :lux_tweet_schedule_queue

  def handler(params, agent) do
    with {:ok, text} <- validate_text(params[:text]),
         {:ok, scheduled_at} <- parse_datetime(params[:scheduled_at], params[:timezone]),
         :ok <- validate_future_time(scheduled_at) do

      agent_name = agent[:name] || "Unknown Agent"
      Logger.info("Agent #{agent_name} scheduling tweet for #{scheduled_at}")

      tweet_id = generate_tweet_id()
      queue_name = params[:queue_name] || "default"

      entry = %{
        id: tweet_id,
        text: text,
        scheduled_at: scheduled_at,
        media_ids: params[:media_ids] || [],
        reply_settings: params[:reply_settings] || "everyone",
        queue_name: queue_name,
        agent: agent_name,
        status: :scheduled,
        created_at: DateTime.utc_now()
      }

      position = enqueue_tweet(entry)

      Logger.info("Tweet #{tweet_id} scheduled at position #{position}")

      {:ok, %{
        scheduled: true,
        tweet_id: tweet_id,
        scheduled_at: DateTime.to_iso8601(scheduled_at),
        queue_position: position
      }}
    end
  end

  defp validate_text(nil), do: {:error, "Missing text parameter"}
  defp validate_text(""), do: {:error, "Tweet text cannot be empty"}
  defp validate_text(text) when byte_size(text) > 280, do: {:error, "Tweet exceeds 280 characters"}
  defp validate_text(text), do: {:ok, text}

  defp parse_datetime(datetime_str, nil), do: parse_datetime(datetime_str, "Etc/UTC")
  defp parse_datetime(datetime_str, timezone) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, utc_dt, _offset} ->
        {:ok, Calendar.DateTime.add(utc_dt, 0, timezone)}
      {:error, _} ->
        case NaiveDateTime.from_iso8601(datetime_str) do
          {:ok, ndt} ->
            {:ok, DateTime.from_naive!(ndt, timezone)}
          {:error, _} ->
            {:error, "Invalid datetime format. Use ISO 8601 (e.g., 2025-03-01T10:00:00Z)"}
        end
    end
  end

  defp validate_future_time(scheduled_at) do
    now = DateTime.utc_now()
    diff = DateTime.diff(scheduled_at, now, :second)

    cond do
      diff < 0 -> {:error, "Scheduled time must be in the future"}
      diff > 30 * 24 * 3600 -> {:error, "Cannot schedule more than 30 days in advance"}
      true -> :ok
    end
  end

  defp enqueue_tweet(entry) do
    ensure_queue_table()
    queue_entries = :ets.lookup(@queue_table, entry.queue_name)
    current_queue = case queue_entries do
      [{_, list}] -> list
      [] -> []
    end

    new_queue = current_queue ++ [entry]
    :ets.insert(@queue_table, {entry.queue_name, new_queue})
    length(new_queue)
  end

  defp ensure_queue_table do
    case :ets.whereis(@queue_table) do
      :undefined -> :ets.new(@queue_table, [:named_table, :public, :set])
      _ -> :ok
    end
  end

  defp generate_tweet_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
