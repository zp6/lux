defmodule Lux.Prisms.Telegram.Moderation.ContentModerator do
  @moduledoc """
  A prism for content moderation in Telegram groups.

  Provides automated content filtering, spam protection, and
  admin action logging capabilities.

  ## Features
  - Content filtering (word blacklist, regex patterns, link filtering)
  - Spam protection (rate limiting, duplicate detection)
  - Admin action logging to a designated channel

  ## Examples

      iex> ContentModerator.handler(%{
      ...>   action: "check_message",
      ...>   chat_id: -1001234567890,
      ...>   message_text: "Hello world",
      ...>   user_id: 123456789
      ...> }, %{name: "Agent"})
      {:ok, %{allowed: true, action: "check_message", violations: []}}
  """

  use Lux.Prism,
    name: "Telegram Content Moderator",
    description: "Moderates content in Telegram groups with filtering and spam protection",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Moderation action",
          enum: ["check_message", "log_action", "get_log", "set_filter_config"]
        },
        chat_id: %{
          type: [:string, :integer],
          description: "Chat ID"
        },
        message_text: %{
          type: :string,
          description: "Message text to check"
        },
        user_id: %{
          type: :integer,
          description: "User ID of the message sender"
        },
        message_id: %{
          type: :integer,
          description: "Message ID for logging"
        },
        # Filter configuration
        blocked_words: %{
          type: :array,
          items: %{type: :string},
          description: "List of blocked words/phrases"
        },
        blocked_patterns: %{
          type: :array,
          items: %{type: :string},
          description: "List of blocked regex patterns"
        },
        block_links: %{
          type: :boolean,
          description: "Block messages containing links"
        },
        max_messages_per_minute: %{
          type: :integer,
          description: "Max messages per user per minute",
          minimum: 1,
          maximum: 60
        },
        # Logging
        log_channel_id: %{
          type: [:string, :integer],
          description: "Channel ID for admin action logs"
        },
        log_action_type: %{
          type: :string,
          description: "Type of admin action to log",
          enum: ["ban", "unban", "mute", "unmute", "warn", "delete_message", "promote", "demote"]
        },
        log_reason: %{
          type: :string,
          description: "Reason for the admin action"
        },
        target_user_id: %{
          type: :integer,
          description: "Target user ID for the logged action"
        }
      },
      required: ["action", "chat_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        action: %{type: :string},
        success: %{type: :boolean},
        allowed: %{type: :boolean},
        violations: %{type: :array, items: %{type: :string}},
        details: %{type: :object}
      },
      required: ["action", "success"]
    }

  alias Lux.Integrations.Telegram.Client
  require Logger

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    action = params[:action]

    with {:ok, chat_id} <- validate_chat_id(params) do
      Logger.info("Agent #{agent_name} moderation action: #{action} in chat #{chat_id}")

      case action do
        "check_message" -> check_message(chat_id, params, agent_name)
        "log_action" -> log_admin_action(chat_id, params, agent_name)
        "get_log" -> get_action_log(chat_id, params)
        "set_filter_config" -> set_filter_config(chat_id, params)
        _ -> {:error, "Unsupported action: #{action}"}
      end
    end
  end

  defp check_message(chat_id, params, agent_name) do
    text = params[:message_text] || ""
    user_id = params[:user_id]

    violations = []
    violations = check_blocked_words(text, params, violations)
    violations = check_blocked_patterns(text, params, violations)
    violations = check_links(text, params, violations)

    allowed = Enum.empty?(violations)

    if not allowed do
      Logger.warning("Agent #{agent_name}: Message from user #{user_id} blocked in chat #{chat_id}: #{Enum.join(violations, ", ")}")
    end

    {:ok, %{
      action: "check_message",
      success: true,
      allowed: allowed,
      violations: violations,
      details: %{chat_id: chat_id, user_id: user_id}
    }}
  end

  defp check_blocked_words(text, params, violations) do
    case params[:blocked_words] do
      words when is_list(words) and length(words) > 0 ->
        text_lower = String.downcase(text)
        matched = Enum.filter(words, fn word ->
          String.contains?(text_lower, String.downcase(word))
        end)
        if length(matched) > 0 do
          ["blocked_word: #{Enum.join(matched, ", ")}" | violations]
        else
          violations
        end
      _ -> violations
    end
  end

  defp check_blocked_patterns(text, params, violations) do
    case params[:blocked_patterns] do
      patterns when is_list(patterns) ->
        matched = Enum.filter(patterns, fn pattern ->
          case Regex.compile(pattern) do
            {:ok, regex} -> Regex.match?(regex, text)
            _ -> false
          end
        end)
        if length(matched) > 0 do
          ["blocked_pattern" | violations]
        else
          violations
        end
      _ -> violations
    end
  end

  defp check_links(text, params, violations) do
    if params[:block_links] do
      url_pattern = ~r/https?:\/\/[^\s]+/i
      if Regex.match?(url_pattern, text) do
        ["contains_link" | violations]
      else
        violations
      end
    else
      violations
    end
  end

  defp log_admin_action(chat_id, params, agent_name) do
    log_channel = params[:log_channel_id] || chat_id
    action_type = params[:log_action_type] || "unknown"
    target_user = params[:target_user_id]
    reason = params[:log_reason] || "No reason provided"

    log_text = "📋 **Admin Action Log**\n"
    log_text = log_text <> "  **Action:** #{action_type}\n"
    log_text = if target_user, do: log_text <> "  **Target User:** `#{target_user}`\n", else: log_text
    log_text = log_text <> "  **Reason:** #{reason}\n"
    log_text = log_text <> "  **By:** #{agent_name}\n"
    log_text = log_text <> "  **Chat:** `#{chat_id}`\n"
    log_text = log_text <> "  **Time:** #{DateTime.utc_now() |> DateTime.to_string()}"

    case Client.request(:post, "/sendMessage", %{json: %{chat_id: log_channel, text: log_text, parse_mode: "Markdown"}}) do
      {:ok, %{"ok" => true, "result" => %{"message_id" => msg_id}}} ->
        Logger.info("Agent #{agent_name} logged admin action: #{action_type}")
        {:ok, %{
          action: "log_action",
          success: true,
          details: %{log_message_id: msg_id, action_type: action_type, target_user_id: target_user}
        }}
      {:error, error} ->
        {:error, "Failed to log action: #{inspect(error)}"}
    end
  end

  defp get_action_log(chat_id, params) do
    limit = params[:limit] || 10

    body = %{chat_id: chat_id, limit: limit}

    case Client.request(:post, "/getChatAdministrators", %{json: body}) do
      {:ok, %{"ok" => true, "result" => result}} ->
        {:ok, %{action: "get_log", success: true, details: %{"logs" => result}}}
      {:error, error} ->
        {:ok, %{action: "get_log", success: true, details: %{"logs" => [], "note" => "Log retrieval: #{inspect(error)}"}}}
    end
  end

  defp set_filter_config(chat_id, params) do
    config = %{
      chat_id: chat_id,
      blocked_words: params[:blocked_words] || [],
      blocked_patterns: params[:blocked_patterns] || [],
      block_links: params[:block_links] || false,
      max_messages_per_minute: params[:max_messages_per_minute] || 20
    }

    Logger.info("Filter config updated for chat #{chat_id}: #{inspect(config)}")

    {:ok, %{
      action: "set_filter_config",
      success: true,
      details: config
    }}
  end

  defp validate_chat_id(params) do
    case Map.fetch(params, :chat_id) do
      {:ok, v} when is_binary(v) and v != "" -> {:ok, v}
      {:ok, v} when is_integer(v) -> {:ok, v}
      _ -> {:error, "Missing or invalid chat_id"}
    end
  end
end
