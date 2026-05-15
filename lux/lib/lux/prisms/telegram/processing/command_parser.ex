defmodule Lux.Prisms.Telegram.Processing.CommandParser do
  @moduledoc """
  A prism for parsing Telegram bot commands and extracting parameters.

  Handles command routing, parameter extraction (positional and named),
  flag detection, and quoted string handling.

  ## Examples

      iex> CommandParser.handler(%{
      ...>   text: "/remind @user Buy groceries --priority high --at \"tomorrow 9am\"",
      ...>   chat_id: 123
      ...> }, %{name: "Agent"})
      {:ok, %{command: "remind", params: %{...}, raw_args: "..."}}
  """

  use Lux.Prism,
    name: "Parse Telegram Command",
    description: "Parses bot commands with parameter extraction and routing",
    input_schema: %{
      type: :object,
      properties: %{
        text: %{
          type: :string,
          description: "Raw message text to parse as a command"
        },
        chat_id: %{
          type: [:string, :integer],
          description: "Chat ID where the command was sent"
        },
        message_id: %{
          type: :integer,
          description: "Original message ID"
        },
        bot_username: %{
          type: :string,
          description: "Bot username for command stripping (e.g., 'mybot')"
        },
        allowed_commands: %{
          type: :array,
          items: %{type: :string},
          description: "List of allowed commands (empty = all allowed)"
        }
      },
      required: ["text", "chat_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        is_command: %{type: :boolean},
        command: %{type: :string},
        args: %{type: :array},
        named_params: %{type: :object},
        flags: %{type: :array},
        raw_args: %{type: :string},
        error: %{type: :string}
      },
      required: ["is_command"]
    }

  require Logger

  def handler(params, agent) do
    with {:ok, text} <- validate_text(params[:text]) do
      agent_name = agent[:name] || "Unknown Agent"
      bot_username = params[:bot_username]

      # Strip bot username from command if present (e.g., /help@mybot -> /help)
      cleaned_text = strip_bot_username(text, bot_username)

      case parse_command(cleaned_text) do
        {:ok, command, raw_args} ->
          command_name = String.trim_leading(command, "/")

          # Check if command is allowed
          case check_allowed(command_name, params[:allowed_commands]) do
            :ok ->
              {args, named_params, flags} = parse_arguments(raw_args)

              Logger.info("Agent #{agent_name} parsed command: /#{command_name}")

              {:ok, %{
                is_command: true,
                command: command_name,
                args: args,
                named_params: named_params,
                flags: flags,
                raw_args: raw_args
              }}

            {:error, reason} ->
              {:ok, %{
                is_command: false,
                command: command_name,
                error: reason,
                args: [],
                named_params: %{},
                flags: [],
                raw_args: raw_args
              }}
          end

        :not_a_command ->
          {:ok, %{is_command: false, command: nil, args: [], named_params: %{}, flags: [], raw_args: ""}}
      end
    end
  end

  defp strip_bot_username(text, nil), do: text
  defp strip_bot_username(text, username) do
    String.replace(text, "@#{username}", "")
  end

  defp parse_command(text) do
    case Regex.run(~r/^\/([a-zA-Z0-9_]+)(?:\s+(.*))?$/s, text) do
      [_, command, raw_args] -> {:ok, "/" <> command, String.trim(raw_args)}
      [_, command] -> {:ok, "/" <> command, ""}
      nil -> :not_a_command
    end
  end

  defp parse_arguments(raw_args) do
    # Tokenize respecting quoted strings
    tokens = tokenize(raw_args)

    {args, named_params, flags} =
      Enum.reduce(tokens, {[], %{}, []}, fn token, {acc_args, acc_params, acc_flags} ->
        cond do
          # Named parameter: --key=value or --key value
          String.starts_with?(token, "--") ->
            case String.split(token, "=", parts: 2) do
              [key, value] ->
                clean_key = String.trim_leading(key, "--")
                {acc_args, Map.put(acc_params, clean_key, unquote_value(value)), acc_flags}
              [key] ->
                {acc_args, Map.put(acc_params, String.trim_leading(key, "--"), true), acc_flags}
            end

          # Short flag: -f
          String.starts_with?(token, "-") and not String.starts_with?(token, "--") ->
            flag = String.trim_leading(token, "-")
            {acc_args, acc_params, [flag | acc_flags]}

          # Positional argument
          true ->
            {[token | acc_args], acc_params, acc_flags}
        end
      end)

    {Enum.reverse(args), named_params, Enum.reverse(flags)}
  end

  defp tokenize(text) do
    # Handle quoted strings and regular tokens
    ~r/(?:"([^"]*)"|'([^']*)'|(\S+))/
    |> Regex.scan(text)
    |> Enum.map(fn
      [_, quoted, _, _] when quoted != "" -> quoted
      [_, _, quoted, _] when quoted != "" -> quoted
      [_, _, _, unquoted] -> unquoted
    end)
  end

  defp unquote_value(value) do
    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        String.slice(value, 1..-2//1)
      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        String.slice(value, 1..-2//1)
      true ->
        value
    end
  end

  defp check_allowed(_command, nil), do: :ok
  defp check_allowed(_command, []), do: :ok
  defp check_allowed(command, allowed) do
    if command in allowed do
      :ok
    else
      {:error, "Command /#{command} is not allowed. Allowed: #{Enum.join(allowed, ", ")}"}
    end
  end

  defp validate_text(nil), do: {:error, "Missing text parameter"}
  defp validate_text(""), do: {:error, "Text cannot be empty"}
  defp validate_text(text), do: {:ok, text}
end
