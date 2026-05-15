defmodule Lux.Prisms.Twitter.Tweets.TweetManager do
  @moduledoc """
  A prism for managing tweets — creating, deleting, editing, quoting,
  and creating tweet threads via the Twitter API v2.

  ## Examples

      iex> TweetManager.handler(%{
      ...>   action: "create",
      ...>   text: "Hello from Lux!"
      ...> }, %{name: "Agent"})
      {:ok, %{tweet_id: "123", text: "Hello from Lux!", created: true}}
  """

  use Lux.Prism,
    name: "Manage Tweets",
    description: "Creates, deletes, edits, quotes tweets and creates threads via Twitter API v2",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: create, delete, edit, quote, create_thread, get",
          enum: ["create", "delete", "edit", "quote", "create_thread", "get"]
        },
        text: %{
          type: :string,
          description: "Tweet text content"
        },
        tweet_id: %{
          type: :string,
          description: "Tweet ID (for delete/edit/get/quote)"
        },
        media_ids: %{
          type: :array,
          items: %{type: :string},
          description: "Media IDs to attach"
        },
        reply_settings: %{
          type: :string,
          description: "Who can reply: mentioned_users, following, everyone",
          enum: ["mentioned_users", "following", "everyone"]
        },
        quote_tweet_id: %{
          type: :string,
          description: "Tweet ID to quote"
        },
        tweets: %{
          type: :array,
          items: %{type: :string},
          description: "Array of tweet texts for thread creation"
        },
        exclude_reply_user_ids: %{
          type: :array,
          items: %{type: :string},
          description: "User IDs to exclude from reply"
        }
      },
      required: ["action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        action: %{type: :string},
        tweet_id: %{type: :string},
        tweet_ids: %{type: :array},
        text: %{type: :string},
        created: %{type: :boolean},
        deleted: %{type: :boolean}
      }
    }

  alias Lux.Integrations.Twitter.Client
  require Logger

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"

    case params[:action] do
      "create" -> create_tweet(params, agent_name)
      "delete" -> delete_tweet(params, agent_name)
      "edit" -> edit_tweet(params, agent_name)
      "quote" -> quote_tweet(params, agent_name)
      "create_thread" -> create_thread(params, agent_name)
      "get" -> get_tweet(params)
      _ -> {:error, "Unknown action: #{params[:action]}"}
    end
  end

  defp create_tweet(params, agent_name) do
    with {:ok, text} <- validate_text(params[:text]) do
      Logger.info("Agent #{agent_name} creating tweet: #{String.slice(text, 0, 50)}...")

      body = %{text: text}
      body = maybe_add_media(body, params[:media_ids])
      body = maybe_add_reply_settings(body, params[:reply_settings])
      body = maybe_add_quote(body, params[:quote_tweet_id])
      body = maybe_add_exclude_reply_users(body, params[:exclude_reply_user_ids])

      case Client.request(:post, "/tweets", %{json: body}) do
        {:ok, %{"data" => %{"id" => id, "text" => tweet_text}}} ->
          {:ok, %{action: "create", tweet_id: id, text: tweet_text, created: true}}

        {:error, {:rate_limited, reset}} ->
          {:error, "Rate limited. Resets at #{reset}"}

        {:error, reason} ->
          {:error, "Failed to create tweet: #{inspect(reason)}"}
      end
    end
  end

  defp delete_tweet(params, agent_name) do
    case params[:tweet_id] do
      nil -> {:error, "Missing tweet_id"}
      id ->
        Logger.info("Agent #{agent_name} deleting tweet #{id}")

        case Client.request(:delete, "/tweets/#{id}", %{}) do
          {:ok, %{"data" => %{"deleted" => true}}} ->
            {:ok, %{action: "delete", tweet_id: id, deleted: true}}

          {:error, reason} ->
            {:error, "Failed to delete tweet: #{inspect(reason)}"}
        end
    end
  end

  defp edit_tweet(params, agent_name) do
    with {:ok, tweet_id} <- validate_required(params[:tweet_id], "tweet_id"),
         {:ok, text} <- validate_text(params[:text]) do

      Logger.info("Agent #{agent_name} editing tweet #{tweet_id}")

      body = %{text: text}

      case Client.request(:put, "/tweets/#{tweet_id}", %{json: body}) do
        {:ok, %{"data" => %{"id" => id, "text" => edited_text, "edit_history_ids" => history}}} ->
          {:ok, %{action: "edit", tweet_id: id, text: edited_text, edit_history: history}}

        {:error, reason} ->
          {:error, "Failed to edit tweet: #{inspect(reason)}"}
      end
    end
  end

  defp quote_tweet(params, agent_name) do
    with {:ok, text} <- validate_text(params[:text]) do
      Logger.info("Agent #{agent_name} creating quote tweet")

      create_tweet(Map.put(params, "quote_tweet_id", params[:quote_tweet_id]), agent_name)
    end
  end

  defp create_thread(params, agent_name) do
    case params[:tweets] do
      nil -> {:error, "Missing tweets array"}
      [] -> {:error, "Tweets array cannot be empty"}
      [single] ->
        create_tweet(%{text: single, media_ids: params[:media_ids], reply_settings: params[:reply_settings]}, agent_name)

      tweets ->
        Logger.info("Agent #{agent_name} creating thread with #{length(tweets)} tweets")

        result = Enum.reduce_while(tweets, {:ok, nil, []}, fn tweet_text, {:ok, prev_id, ids} ->
          body = %{text: tweet_text}
          body = if prev_id do
            put_in(body, [:reply, :in_reply_to_tweet_id], prev_id)
          else
            body
          end

          case Client.request(:post, "/tweets", %{json: body}) do
            {:ok, %{"data" => %{"id" => new_id}}} ->
              {:cont, {:ok, new_id, [new_id | ids]}}

            {:error, reason} ->
              {:halt, {:error, "Thread failed at tweet: #{inspect(reason)}, partial IDs: #{inspect(Enum.reverse(ids))}"}}
          end
        end)

        case result do
          {:ok, last_id, ids} ->
            {:ok, %{action: "create_thread", tweet_ids: Enum.reverse(ids), last_tweet_id: last_id, created: true}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp get_tweet(params) do
    case params[:tweet_id] do
      nil -> {:error, "Missing tweet_id"}
      id ->
        case Client.request(:get, "/tweets/#{id}", %{params: %{"tweet.fields" => "created_at,public_metrics,author_id,edit_history"}}) do
          {:ok, %{"data" => tweet}} ->
            {:ok, %{action: "get", tweet: tweet}}

          {:error, reason} ->
            {:error, "Failed to get tweet: #{inspect(reason)}"}
        end
    end
  end

  defp maybe_add_media(body, nil), do: body
  defp maybe_add_media(body, []), do: body
  defp maybe_add_media(body, media_ids), do: put_in(body, [:media, :media_ids], media_ids)

  defp maybe_add_reply_settings(body, nil), do: body
  defp maybe_add_reply_settings(body, setting), do: Map.put(body, :reply_settings, setting)

  defp maybe_add_quote(body, nil), do: body
  defp maybe_add_quote(body, quote_id), do: put_in(body, [:quote_tweet_id], quote_id)

  defp maybe_add_exclude_reply_users(body, nil), do: body
  defp maybe_add_exclude_reply_users(body, ids), do: put_in(body, [:reply, :exclude_reply_user_ids], ids)

  defp validate_text(nil), do: {:error, "Missing text parameter"}
  defp validate_text(""), do: {:error, "Text cannot be empty"}
  defp validate_text(text) when byte_size(text) > 280, do: {:error, "Tweet exceeds 280 characters"}
  defp validate_text(text), do: {:ok, text}

  defp validate_required(nil, field), do: {:error, "Missing #{field}"}
  defp validate_required(value, _field), do: {:ok, value}
end
