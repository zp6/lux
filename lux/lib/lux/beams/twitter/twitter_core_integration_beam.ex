defmodule Lux.Beams.Twitter.TwitterCoreIntegrationBeam do
  @moduledoc """
  A beam that orchestrates the complete Twitter API core integration workflow.

  This beam handles authentication, media upload, tweet creation, and rate limit
  management in a unified pipeline for reliable Twitter API interactions.

  ## Workflow

  1. Check rate limits before proceeding
  2. Authenticate via OAuth 2.0 if needed
  3. Upload any media attachments
  4. Create the tweet (or thread)
  5. Record rate limit usage

  ## Example

      Lux.Beams.Twitter.TwitterCoreIntegrationBeam.run(%{
        text: "Check out this amazing view!",
        media_paths: ["/path/to/image.jpg"],
        reply_settings: "everyone"
      })
  """

  use Lux.Beam,
    name: "Twitter API Core Integration",
    description: "Orchestrates authentication, media upload, tweet creation, and rate limiting",
    input_schema: %{
      type: :object,
      properties: %{
        text: %{
          type: :string,
          description: "Tweet text content"
        },
        media_paths: %{
          type: :array,
          items: %{type: :string},
          description: "Local file paths for media to upload and attach"
        },
        media_urls: %{
          type: :array,
          items: %{type: :string},
          description: "URLs of media to upload and attach"
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
        thread_tweets: %{
          type: :array,
          items: %{type: :string},
          description: "Array of tweet texts for creating a thread"
        },
        token_set_id: %{
          type: :string,
          description: "Stored OAuth token set ID"
        }
      },
      required: ["text"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        status: %{type: :string},
        tweet_id: %{type: :string},
        tweet_ids: %{type: :array},
        media_ids: %{type: :array}
      },
      required: ["status"]
    },
    generate_execution_log: true

  alias Lux.Prisms.Twitter.Auth.RateLimitManager
  alias Lux.Prisms.Twitter.Media.MediaUploader
  alias Lux.Prisms.Twitter.Tweets.TweetManager

  require Logger

  sequence do
    # Step 1: Check rate limits
    step(:check_rate_limit, RateLimitManager, %{
      action: "check",
      endpoint: "/tweets",
      method: "POST"
    })

    # Step 2: Wait if rate limited
    step(:wait_if_needed, RateLimitManager, %{
      action: "wait_if_needed",
      endpoint: "/tweets",
      method: "POST"
    })

    # Step 3: Upload media files if any
    step(:upload_media, MediaUploader, %{
      action: "upload",
      file_path: [:input, :media_paths]
    })

    # Step 4: Create tweet with attached media
    step(:create_tweet, TweetManager, %{
      action: "create",
      text: [:input, :text],
      media_ids: [:steps, :upload_media, :result, :media_id],
      reply_settings: [:input, :reply_settings],
      quote_tweet_id: [:input, :quote_tweet_id]
    })

    # Step 5: Record rate limit usage
    step(:record_usage, RateLimitManager, %{
      action: "record",
      endpoint: "/tweets",
      method: "POST"
    })
  end
end
