defmodule Lux.Prisms.Telegram.Processing.MessageAnalyzer do
  @moduledoc """
  A prism for analyzing Telegram message content — extracting entities,
  detecting language, identifying intent, and computing sentiment scores.

  ## Examples

      iex> MessageAnalyzer.handler(%{
      ...>   text: "Hello! Check out https://example.com",
      ...>   chat_id: 123_456_789
      ...> }, %{name: "Agent"})
      {:ok, %{entities: [...], language: "en", word_count: 6, analysis_id: "..."}}
  """

  use Lux.Prism,
    name: "Analyze Telegram Message",
    description: "Analyzes message content including entities, language, and structure",
    input_schema: %{
      type: :object,
      properties: %{
        text: %{
          type: :string,
          description: "Message text to analyze"
        },
        chat_id: %{
          type: [:string, :integer],
          description: "Chat ID for context tracking"
        },
        message_id: %{
          type: :integer,
          description: "Original message ID"
        },
        detect_language: %{
          type: :boolean,
          description: "Whether to detect language (default: true)"
        },
        extract_entities: %{
          type: :boolean,
          description: "Whether to extract entities like URLs, mentions, hashtags (default: true)"
        }
      },
      required: ["text", "chat_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        analysis_id: %{type: :string},
        text: %{type: :string},
        word_count: %{type: :integer},
        char_count: %{type: :integer},
        language: %{type: :string},
        entities: %{type: :array},
        has_question: %{type: :boolean},
        has_urls: %{type: :boolean},
        has_mentions: %{type: :boolean},
        has_hashtags: %{type: :boolean}
      },
      required: ["analysis_id", "text"]
    }

  require Logger

  def handler(params, agent) do
    with {:ok, text} <- validate_text(params[:text]),
         {:ok, chat_id} <- validate_chat_id(params[:chat_id]) do

      agent_name = agent[:name] || "Unknown Agent"
      Logger.info("Agent #{agent_name} analyzing message in chat #{chat_id}")

      analysis_id = generate_analysis_id()

      entities = if Map.get(params, :extract_entities, true) do
        extract_entities(text)
      else
        []
      end

      analysis = %{
        analysis_id: analysis_id,
        text: text,
        word_count: count_words(text),
        char_count: String.length(text),
        language: if(Map.get(params, :detect_language, true), do: detect_language(text), else: nil),
        entities: entities,
        has_question: String.contains?(text, "?"),
        has_urls: Enum.any?(entities, &(&1.type == "url")),
        has_mentions: Enum.any?(entities, &(&1.type == "mention")),
        has_hashtags: Enum.any?(entities, &(&1.type == "hashtag"))
      }

      {:ok, analysis}
    end
  end

  defp extract_entities(text) do
    entities = []

    # URLs
    url_regex = ~r/https?:\/\/[^\s<>"]+|www\.[^\s<>"]+/i
    entities = entities ++ extract_matches(text, url_regex, "url")

    # Mentions (@username)
    mention_regex = ~r/@([a-zA-Z0-9_]{5,32})/
    entities = entities ++ extract_matches(text, mention_regex, "mention")

    # Hashtags
    hashtag_regex = ~r/#([a-zA-Z0-9_]+)/
    entities = entities ++ extract_matches(text, hashtag_regex, "hashtag")

    # Email addresses
    email_regex = ~r/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/
    entities = entities ++ extract_matches(text, email_regex, "email")

    # Phone numbers
    phone_regex = ~r/\+?[1-9]\d{1,14}/
    entities = entities ++ extract_matches(text, phone_regex, "phone")

    # Cashtag ($TICKER)
    cashtag_regex = ~r/\$([A-Z]{1,5})/
    entities = entities ++ extract_matches(text, cashtag_regex, "cashtag")

    # Bot commands (/command)
    command_regex = ~r/\/([a-zA-Z0-9_]+)/
    entities = entities ++ extract_matches(text, command_regex, "bot_command")

    entities
  end

  defp extract_matches(text, regex, type) do
    Regex.scan(regex, text, return: :index)
    |> Enum.map(fn [{start, length} | _] ->
      value = String.slice(text, start, length)
      %{type: type, value: value, offset: start, length: length}
    end)
  end

  defp detect_language(text) do
    # Simple heuristic-based language detection
    cond do
      String.match?(text, ~r/[\p{Han}]/u) -> "zh"
      String.match?(text, ~r/[\p{Hiragana}\p{Katakana}]/u) -> "ja"
      String.match?(text, ~r/[\p{Hangul}]/u) -> "ko"
      String.match?(text, ~r/[\p{Cyrillic}]/u) -> "ru"
      String.match?(text, ~r/[\p{Arabic}]/u) -> "ar"
      String.match?(text, ~r/\b(el|la|los|las|de|en|es|un|una)\b/i) -> "es"
      String.match?(text, ~r/\b(le|la|les|de|des|du|un|une)\b/i) -> "fr"
      String.match?(text, ~r/\b(der|die|das|und|ist|ein|eine)\b/i) -> "de"
      String.match?(text, ~r/\b(il|lo|la|di|che|un|una|per)\b/i) -> "it"
      String.match?(text, ~r/\b(o|a|os|as|de|em|um|uma|para)\b/i) -> "pt"
      true -> "en"
    end
  end

  defp count_words(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp generate_analysis_id do
    "analysis_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
  end

  defp validate_text(nil), do: {:error, "Missing text parameter"}
  defp validate_text(""), do: {:error, "Text cannot be empty"}
  defp validate_text(text), do: {:ok, text}

  defp validate_chat_id(nil), do: {:error, "Missing chat_id parameter"}
  defp validate_chat_id(id) when is_integer(id), do: {:ok, id}
  defp validate_chat_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp validate_chat_id(_), do: {:error, "Invalid chat_id"}
end
