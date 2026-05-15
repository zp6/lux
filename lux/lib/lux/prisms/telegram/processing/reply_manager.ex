defmodule Lux.Prisms.Telegram.Processing.ReplyManager do
  @moduledoc """
  A prism for managing message replies — tracking reply chains,
  constructing contextual replies, and managing reply templates.

  ## Examples

      iex> ReplyManager.handler(%{
      ...>   action: "send_reply",
      ...>   chat_id: 123,
      ...>   reply_to_message_id: 42,
      ...>   text: "Here's your answer"
      ...> }, %{name: "Agent"})
      {:ok, %{sent: true, message_id: 99, reply_to: 42}}
  """

  use Lux.Prism,
    name: "Manage Telegram Replies",
    description: "Manages reply chains, contextual replies, and reply templates",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: send_reply, get_chain, add_template, list_templates, apply_template",
          enum: ["send_reply", "get_chain", "add_template", "list_templates", "apply_template"]
        },
        chat_id: %{
          type: [:string, :integer],
          description: "Chat ID"
        },
        reply_to_message_id: %{
          type: :integer,
          description: "Message ID to reply to"
        },
        text: %{
          type: :string,
          description: "Reply text content"
        },
        parse_mode: %{
          type: :string,
          description: "Message format: Markdown, MarkdownV2, HTML",
          enum: ["Markdown", "MarkdownV2", "HTML"]
        },
        template_name: %{
          type: :string,
          description: "Name of a reply template"
        },
        template: %{
          type: :object,
          properties: %{
            name: %{type: :string},
            text: %{type: :string},
            parse_mode: %{type: :string},
            variables: %{type: :array, items: %{type: :string}}
          }
        },
        variables: %{
          type: :object,
          description: "Key-value pairs for template variable substitution"
        },
        max_chain_depth: %{
          type: :integer,
          description: "Maximum reply chain depth to retrieve (default: 20)"
        }
      },
      required: ["action", "chat_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        sent: %{type: :boolean},
        message_id: %{type: :integer},
        reply_to: %{type: :integer},
        chain: %{type: :array},
        templates: %{type: :array}
      }
    }

  alias Lux.Integrations.Telegram.Client
  require Logger

  @chains_table :lux_reply_chains
  @templates_table :lux_reply_templates

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    ensure_tables()

    case params[:action] do
      "send_reply" -> send_reply(params, agent_name)
      "get_chain" -> get_chain(params)
      "add_template" -> add_template(params)
      "list_templates" -> list_templates()
      "apply_template" -> apply_template(params, agent_name)
      _ -> {:error, "Unknown action: #{params[:action]}"}
    end
  end

  defp send_reply(params, agent_name) do
    with {:ok, chat_id} <- validate_required(params[:chat_id], "chat_id"),
         {:ok, reply_to} <- validate_required(params[:reply_to_message_id], "reply_to_message_id"),
         {:ok, text} <- validate_required(params[:text], "text") do

      Logger.info("Agent #{agent_name} sending reply in chat #{chat_id} to message #{reply_to}")

      request_body = %{
        chat_id: chat_id,
        text: text,
        reply_to_message_id: reply_to
      }
      |> maybe_add_parse_mode(params[:parse_mode])

      case Client.request(:post, "/sendMessage", %{json: request_body}) do
        {:ok, %{"result" => %{"message_id" => msg_id}}} ->
          record_reply(chat_id, msg_id, reply_to, text)
          {:ok, %{sent: true, message_id: msg_id, reply_to: reply_to}}

        {:error, reason} ->
          {:error, "Failed to send reply: #{inspect(reason)}"}
      end
    end
  end

  defp get_chain(params) do
    chat_id = params[:chat_id]
    max_depth = params[:max_chain_depth] || 20

    case params[:reply_to_message_id] do
      nil -> {:error, "Missing reply_to_message_id"}
      msg_id ->
        chain = build_chain(chat_id, msg_id, max_depth, [])
        {:ok, %{chain: chain, depth: length(chain)}}
    end
  end

  defp add_template(params) do
    template = params[:template]
    case template do
      nil -> {:error, "Missing template parameter"}
      %{name: name, text: text} when is_binary(name) and is_binary(text) ->
        entry = %{
          name: name,
          text: text,
          parse_mode: template[:parse_mode],
          variables: template[:variables] || extract_variables(text),
          created_at: DateTime.utc_now()
        }

        current = get_all_templates()
        filtered = Enum.reject(current, &(&1.name == name))
        :ets.insert(@templates_table, {:templates, [entry | filtered]})

        {:ok, %{template_name: name, status: "added"}}

      _ ->
        {:error, "Template must have name and text"}
    end
  end

  defp list_templates do
    {:ok, %{templates: get_all_templates()}}
  end

  defp apply_template(params, agent_name) do
    with {:ok, template_name} <- validate_required(params[:template_name], "template_name"),
         {:ok, variables} <- {:ok, params[:variables] || %{}} do

      case Enum.find(get_all_templates(), &(&1.name == template_name)) do
        nil -> {:error, "Template '#{template_name}' not found"}
        template ->
          text = Enum.reduce(variables, template.text, fn {key, value}, acc ->
            String.replace(acc, "{{#{key}}}", to_string(value))
          end)

          # Send if chat_id and reply_to provided
          case {params[:chat_id], params[:reply_to_message_id]} do
            {chat_id, reply_to} when chat_id != nil and reply_to != nil ->
              send_reply(Map.merge(params, %{text: text, parse_mode: template[:parse_mode]}), agent_name)

            _ ->
              {:ok, %{text: text, template_name: template_name, applied: true}}
          end
      end
    end
  end

  defp build_chain(_chat_id, _msg_id, 0, acc), do: Enum.reverse(acc)
  defp build_chain(chat_id, msg_id, depth, acc) do
    case get_reply_record(chat_id, msg_id) do
      nil -> Enum.reverse(acc)
      record ->
        build_chain(chat_id, record.reply_to, depth - 1, [record | acc])
    end
  end

  defp record_reply(chat_id, msg_id, reply_to, text) do
    current = get_chains_for_chat(chat_id)
    entry = %{message_id: msg_id, reply_to: reply_to, text: text, at: DateTime.utc_now()}
    :ets.insert(@chains_table, {{:chat, chat_id}, [entry | current]})
  end

  defp get_reply_record(chat_id, msg_id) do
    get_chains_for_chat(chat_id)
    |> Enum.find(&(&1.message_id == msg_id))
  end

  defp get_chains_for_chat(chat_id) do
    case :ets.lookup(@chains_table, {:chat, chat_id}) do
      [{{:chat, ^chat_id}, chains}] -> chains
      [] -> []
    end
  end

  defp get_all_templates do
    case :ets.lookup(@templates_table, :templates) do
      [{:templates, templates}] -> templates
      [] -> []
    end
  end

  defp extract_variables(text) do
    ~r/\{\{(\w+)\}\}/
    |> Regex.scan(text)
    |> Enum.map(fn [_, var] -> var end)
    |> Enum.uniq()
  end

  defp maybe_add_parse_mode(body, nil), do: body
  defp maybe_add_parse_mode(body, mode), do: Map.put(body, :parse_mode, mode)

  defp validate_required(nil, field), do: {:error, "Missing #{field}"}
  defp validate_required(value, _field), do: {:ok, value}

  defp ensure_tables do
    Enum.each([@chains_table, @templates_table], fn table ->
      case :ets.whereis(table) do
        :undefined -> :ets.new(table, [:named_table, :public, :set])
        _ -> :ok
      end
    end)
  end
end
