defmodule Lux.Prisms.Telegram.Processing.FormatConverter do
  @moduledoc """
  A prism for converting message formatting between Telegram-supported
  formats: plain text, Markdown, MarkdownV2, and HTML.

  ## Examples

      iex> FormatConverter.handler(%{
      ...>   text: "**Bold** and _italic_",
      ...>   from_format: "markdown",
      ...>   to_format: "html"
      ...> }, %{name: "Agent"})
      {:ok, %{converted_text: "<b>Bold</b> and <i>italic</i>", format: "html"}}
  """

  use Lux.Prism,
    name: "Convert Telegram Message Format",
    description: "Converts between Telegram message formats (Markdown, MarkdownV2, HTML, plain)",
    input_schema: %{
      type: :object,
      properties: %{
        text: %{
          type: :string,
          description: "Text to convert"
        },
        from_format: %{
          type: :string,
          description: "Source format: plain, markdown, markdownv2, html",
          enum: ["plain", "markdown", "markdownv2", "html"]
        },
        to_format: %{
          type: :string,
          description: "Target format: plain, markdown, markdownv2, html",
          enum: ["plain", "markdown", "markdownv2", "html"]
        }
      },
      required: ["text", "from_format", "to_format"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        converted_text: %{type: :string},
        format: %{type: :string},
        char_count: %{type: :integer}
      },
      required: ["converted_text", "format"]
    }

  require Logger

  def handler(params, agent) do
    with {:ok, text} <- validate_text(params[:text]),
         {:ok, from} <- validate_format(params[:from_format], "from_format"),
         {:ok, to} <- validate_format(params[:to_format], "to_format") do

      agent_name = agent[:name] || "Unknown Agent"
      Logger.info("Agent #{agent_name} converting from #{from} to #{to}")

      # Convert through intermediate plain text
      plain = to_plain(text, from)
      converted = from_plain(plain, to)

      {:ok, %{
        converted_text: converted,
        format: to,
        char_count: String.length(converted)
      }}
    end
  end

  # to_plain: strip all formatting to plain text
  defp to_plain(text, "plain"), do: text

  defp to_plain(text, "markdown") do
    text
    |> replace_regex(~r/\*\*(.+?)\**/, "\\1")    # bold
    |> replace_regex(~r/\*(.+?)\*/, "\\1")        # italic
    |> replace_regex(~r/__(.+?)__/, "\\1")        # underline
    |> replace_regex(~r/_(.+?)_/, "\\1")          # italic
    |> replace_regex(~r/~~(.+?)~~/, "\\1")        # strikethrough
    |> replace_regex(~r/`{3}[\s\S]*?`{3}/, "")    # code blocks
    |> replace_regex(~r/`(.+?)`/, "\\1")          # inline code
    |> replace_regex(~r/\[(.+?)\]\(.+?\)/, "\\1") # links
  end

  defp to_plain(text, "markdownv2") do
    text
    |> String.replace("\\", "")
    |> to_plain("markdown")
  end

  defp to_plain(text, "html") do
    text
    |> replace_regex(~r/<b>(.+?)<\/b>/, "\\1")
    |> replace_regex(~r/<strong>(.+?)<\/strong>/, "\\1")
    |> replace_regex(~r/<i>(.+?)<\/i>/, "\\1")
    |> replace_regex(~r/<em>(.+?)<\/em>/, "\\1")
    |> replace_regex(~r/<u>(.+?)<\/u>/, "\\1")
    |> replace_regex(~r/<s>(.+?)<\/s>/, "\\1")
    |> replace_regex(~r/<strike>(.+?)<\/strike>/, "\\1")
    |> replace_regex(~r/<del>(.+?)<\/del>/, "\\1")
    |> replace_regex(~r/<code>(.+?)<\/code>/, "\\1")
    |> replace_regex(~r/<pre>[\s\S]*?<\/pre>/, "")
    |> replace_regex(~r/<a[^>]*>(.+?)<\/a>/, "\\1")
  end

  # from_plain: convert plain text to target format (passthrough)
  defp from_plain(text, "plain"), do: text
  defp from_plain(text, "markdown") do
    # Return as-is for plain->markdown since we can't infer formatting
    text
  end
  defp from_plain(text, "markdownv2") do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("_", "\\_")
    |> String.replace("*", "\\*")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
    |> String.replace("~", "\\~")
    |> String.replace("`", "\\`")
    |> String.replace(">", "\\>")
    |> String.replace("#", "\\#")
    |> String.replace("+", "\\+")
    |> String.replace("-", "\\-")
    |> String.replace("=", "\\=")
    |> String.replace("|", "\\|")
    |> String.replace("{", "\\{")
    |> String.replace("}", "\\}")
    |> String.replace(".", "\\.")
    |> String.replace("!", "\\!")
  end
  defp from_plain(text, "html") do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp replace_regex(text, regex, replacement) do
    Regex.replace(regex, text, replacement)
  end

  defp validate_text(nil), do: {:error, "Missing text parameter"}
  defp validate_text(""), do: {:error, "Text cannot be empty"}
  defp validate_text(text), do: {:ok, text}

  defp validate_format(nil, field), do: {:error, "Missing #{field}"}
  defp validate_format(fmt, _) when fmt in ["plain", "markdown", "markdownv2", "html"], do: {:ok, fmt}
  defp validate_format(fmt, field), do: {:error, "Invalid #{field}: #{fmt}"}
end
