defmodule Lux.Beams.Telegram.MessageProcessingBeam do
  @moduledoc """
  A beam that orchestrates the complete Telegram message processing pipeline.

  This beam chains analysis, command parsing, format conversion, threading,
  and reply management into a unified message processing workflow.

  ## Workflow

  1. Analyze incoming message content (entities, language, structure)
  2. If message is a command, parse and route it
  3. Convert message format if needed
  4. Track message in thread context
  5. Generate and send appropriate reply

  ## Example

      Lux.Beams.Telegram.MessageProcessingBeam.run(%{
        chat_id: 123_456_789,
        text: "/help --format html",
        message_id: 42
      })
  """

  use Lux.Beam,
    name: "Telegram Message Processing",
    description: "Complete message processing pipeline for Telegram messages",
    input_schema: %{
      type: :object,
      properties: %{
        chat_id: %{
          type: [:string, :integer],
          description: "Chat ID where the message was received"
        },
        text: %{
          type: :string,
          description: "Raw message text"
        },
        message_id: %{
          type: :integer,
          description: "Message ID of the incoming message"
        },
        reply_to_message_id: %{
          type: :integer,
          description: "If this is a reply, the original message ID"
        },
        target_format: %{
          type: :string,
          description: "Desired output format for replies",
          enum: ["Markdown", "MarkdownV2", "HTML", "plain"]
        },
        thread_id: %{
          type: :string,
          description: "Existing thread ID to continue, or nil to auto-create"
        }
      },
      required: ["chat_id", "text", "message_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        status: %{type: :string},
        analysis: %{type: :object},
        command: %{type: :object},
        thread_id: %{type: :string},
        reply_sent: %{type: :boolean}
      },
      required: ["status"]
    },
    generate_execution_log: true

  alias Lux.Prisms.Telegram.Processing.MessageAnalyzer
  alias Lux.Prisms.Telegram.Processing.CommandParser
  alias Lux.Prisms.Telegram.Processing.ThreadManager
  alias Lux.Prisms.Telegram.Processing.ReplyManager

  require Logger

  sequence do
    # Step 1: Analyze message content
    step(:analyze, MessageAnalyzer, %{
      text: [:input, :text],
      chat_id: [:input, :chat_id],
      message_id: [:input, :message_id]
    })

    # Step 2: Parse commands if present
    step(:parse_command, CommandParser, %{
      text: [:input, :text],
      chat_id: [:input, :chat_id],
      message_id: [:input, :message_id]
    })

    # Step 3: Track in thread
    step(:thread, ThreadManager, %{
      action: "add_message",
      chat_id: [:input, :chat_id],
      thread_id: [:input, :thread_id],
      message: %{
        message_id: [:input, :message_id],
        text: [:input, :text],
        reply_to: [:input, :reply_to_message_id]
      }
    })

    # Step 4: Determine if we should reply
    branch {__MODULE__, :should_auto_reply?} do
      true ->
        step(:reply, ReplyManager, %{
          action: "send_reply",
          chat_id: [:input, :chat_id],
          reply_to_message_id: [:input, :message_id],
          text: [:steps, :parse_command, :result, :raw_args],
          parse_mode: [:input, :target_format]
        })

      false ->
        step(:no_reply, Lux.Prisms.NoOp, %{
          reply_sent: false
        })
    end
  end

  @doc """
  Determines if an auto-reply should be sent based on parsed command.
  """
  def should_auto_reply?(ctx) do
    case ctx.steps.parse_command.result do
      %{is_command: true, error: nil} -> true
      _ -> false
    end
  end
end
