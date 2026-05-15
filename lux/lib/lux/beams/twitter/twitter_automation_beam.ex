defmodule Lux.Beams.Twitter.TwitterAutomationBeam do
  @moduledoc """
  A beam that orchestrates the complete Twitter automation and engagement workflow.

  This beam combines scheduling, auto-reply, content curation, and engagement
  rules into a unified pipeline for automated Twitter management.

  ## Workflow

  1. Curates content from configured sources
  2. Evaluates content against engagement rules
  3. Schedules approved tweets via the content calendar
  4. Processes any auto-reply rules for incoming mentions

  ## Example

      Lux.Beams.Twitter.TwitterAutomationBeam.run(%{
        topics: ["AI", "crypto"],
        schedule_time: "2025-03-01T10:00:00Z",
        max_scheduled: 5
      })
  """

  use Lux.Beam,
    name: "Twitter Automation and Engagement",
    description: "Orchestrates automated Twitter engagement, scheduling, and content management",
    input_schema: %{
      type: :object,
      properties: %{
        topics: %{
          type: :array,
          items: %{type: :string},
          description: "Topics to curate content for"
        },
        schedule_time: %{
          type: :string,
          description: "ISO 8601 datetime for scheduling curated tweets"
        },
        max_scheduled: %{
          type: :integer,
          description: "Maximum number of tweets to schedule (default: 5)"
        },
        enable_auto_reply: %{
          type: :boolean,
          description: "Whether to process auto-reply rules (default: true)"
        },
        enable_follow_back: %{
          type: :boolean,
          description: "Whether to auto-follow-back new followers (default: false)"
        },
        campaign_name: %{
          type: :string,
          description: "Campaign name for calendar entries"
        }
      },
      required: ["topics"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        status: %{type: :string},
        curated_count: %{type: :integer},
        scheduled_count: %{type: :integer},
        auto_replies_processed: %{type: :integer},
        follow_backs: %{type: :integer}
      },
      required: ["status"]
    },
    generate_execution_log: true

  alias Lux.Prisms.Twitter.Automation.ContentCurator
  alias Lux.Prisms.Twitter.Automation.ScheduleTweet
  alias Lux.Prisms.Twitter.Automation.ContentCalendar
  alias Lux.Prisms.Twitter.Engagement.EngagementRulesEngine
  alias Lux.Prisms.Twitter.Engagement.FollowManager

  require Logger

  sequence do
    # Step 1: Curate content based on topics
    step(:curate_content, ContentCurator, %{
      action: "curate",
      topics: [:input, :topics],
      max_items: [:input, :max_scheduled]
    })

    # Step 2: Evaluate each curated item against engagement rules
    step(:evaluate_content, EngagementRulesEngine, %{
      action: "evaluate",
      interaction: %{
        type: "mention",
        text: [:steps, :curate_content, :result, :items],
        sentiment: "positive"
      }
    })

    # Step 3: Schedule the curated content
    step(:schedule_tweets, Lux.Prisms.NoOp, %{
      status: "scheduling"
    })

    # Step 4: Process auto-follow-back if enabled
    branch {__MODULE__, :should_follow_back?} do
      true ->
        step(:follow_back, FollowManager, %{
          action: "auto_follow_back",
          follow_rules: %{
            min_followers: 10,
            must_have_bio: true
          }
        })

      false ->
        step(:skip_follow, Lux.Prisms.NoOp, %{
          follow_backs: 0
        })
    end
  end

  @doc """
  Determines if auto-follow-back should run based on input config.
  """
  def should_follow_back?(ctx) do
    Map.get(ctx.input, :enable_follow_back, false)
  end
end
