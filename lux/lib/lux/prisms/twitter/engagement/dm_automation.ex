defmodule Lux.Prisms.Twitter.Engagement.DMAutomation do
  @moduledoc """
  A prism for automating Twitter direct message interactions including
  welcome messages, keyword-triggered responses, and conversation flows.

  ## Examples

      iex> DMAutomation.handler(%{
      ...>   action: "send",
      ...>   recipient_id: "123456",
      ...>   text: "Welcome! How can I help?"
      ...> }, %{name: "Agent"})
      {:ok, %{sent: true, message_id: "dm_abc"}}
  """

  use Lux.Prism,
    name: "Twitter DM Automation",
    description: "Automates direct message sending and management on Twitter",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: send, set_welcome, list_conversations, get_history",
          enum: ["send", "set_welcome", "list_conversations", "get_history"]
        },
        recipient_id: %{
          type: :string,
          description: "Twitter user ID to send DM to"
        },
        text: %{
          type: :string,
          description: "Message text to send"
        },
        welcome_message: %{
          type: :object,
          properties: %{
            text: %{type: :string},
            quick_replies: %{
              type: :array,
              items: %{type: :object, properties: %{label: %{type: :string}, action: %{type: :string}}}
            }
          }
        },
        conversation_id: %{
          type: :string,
          description: "DM conversation ID for get_history"
        },
        max_results: %{
          type: :integer,
          description: "Max messages to return (default: 50)"
        }
      },
      required: ["action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        action: %{type: :string},
        sent: %{type: :boolean},
        message_id: %{type: :string},
        conversations: %{type: :array},
        messages: %{type: :array}
      }
    }

  alias Lux.Integrations.Twitter.Client
  require Logger

  @welcome_table :lux_dm_welcome

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    ensure_welcome_table()

    case params[:action] do
      "send" -> send_dm(params, agent_name)
      "set_welcome" -> set_welcome(params, agent_name)
      "list_conversations" -> list_conversations(params)
      "get_history" -> get_history(params)
      _ -> {:error, "Unknown action: #{params[:action]}"}
    end
  end

  defp send_dm(params, agent_name) do
    with {:ok, recipient_id} <- validate_required(params[:recipient_id], "recipient_id"),
         {:ok, text} <- validate_required(params[:text], "text") do

      Logger.info("Agent #{agent_name} sending DM to user #{recipient_id}")

      payload = %{
        event: %{
          type: "message_create",
          message_create: %{
            target: %{recipient_id: recipient_id},
            message_data: %{text: text}
          }
        }
      }

      case Client.request(:post, "/direct_messages/events/new", %{json: payload}) do
        {:ok, response} ->
          message_id = get_in(response, ["data", "event", "id"]) || "dm_unknown"
          {:ok, %{action: "send", sent: true, message_id: message_id}}

        {:error, reason} ->
          {:error, "Failed to send DM: #{inspect(reason)}"}
      end
    end
  end

  defp set_welcome(params, agent_name) do
    case params[:welcome_message] do
      nil -> {:error, "Missing welcome_message parameter"}
      welcome ->
        Logger.info("Agent #{agent_name} setting DM welcome message")

        entry = %{
          text: welcome[:text] || "Welcome! How can we help you?",
          quick_replies: welcome[:quick_replies] || [],
          set_by: agent_name,
          set_at: DateTime.utc_now()
        }

        :ets.insert(@welcome_table, {:welcome, entry})

        {:ok, %{action: "set_welcome", status: "active", message: entry.text}}
    end
  end

  defp list_conversations(params) do
    max_results = params[:max_results] || 50

    case Client.request(:get, "/direct_messages/events/list", %{params: %{max_results: max_results}}) do
      {:ok, %{"data" => events}} ->
        conversations =
          events
          |> Enum.group_by(&get_in(&1, ["event", "message_create", "target", "recipient_id"]))
          |> Enum.map(fn {peer_id, messages} ->
            %{
              peer_id: peer_id,
              last_message: List.first(messages),
              message_count: length(messages)
            }
          end)

        {:ok, %{action: "list_conversations", conversations: conversations}}

      {:error, reason} ->
        {:error, "Failed to list conversations: #{inspect(reason)}"}

      _ ->
        {:ok, %{action: "list_conversations", conversations: []}}
    end
  end

  defp get_history(params) do
    case params[:conversation_id] do
      nil -> {:error, "Missing conversation_id"}
      conv_id ->
        max_results = params[:max_results] || 50

        case Client.request(:get, "/direct_messages/events/list", %{
          params: %{max_results: max_results, conversation_id: conv_id}
        }) do
          {:ok, %{"data" => events}} ->
            {:ok, %{action: "get_history", messages: events}}

          {:error, reason} ->
            {:error, "Failed to get history: #{inspect(reason)}"}

          _ ->
            {:ok, %{action: "get_history", messages: []}}
        end
    end
  end

  defp validate_required(nil, field), do: {:error, "Missing #{field}"}
  defp validate_required("", field), do: {:error, "#{field} cannot be empty"}
  defp validate_required(value, _field), do: {:ok, value}

  defp ensure_welcome_table do
    case :ets.whereis(@welcome_table) do
      :undefined -> :ets.new(@welcome_table, [:named_table, :public, :set])
      _ -> :ok
    end
  end
end
