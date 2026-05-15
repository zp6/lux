defmodule Lux.Prisms.Telegram.Processing.ThreadManager do
  @moduledoc """
  A prism for managing Telegram message threads — tracking conversation
  context, handling reply chains, and maintaining thread state.

  ## Examples

      iex> ThreadManager.handler(%{
      ...>   action: "create",
      ...>   chat_id: 123,
      ...>   topic: "Support Request"
      ...> }, %{name: "Agent"})
      {:ok, %{thread_id: "thread_abc", chat_id: 123, status: "created"}}
  """

  use Lux.Prism,
    name: "Manage Telegram Thread",
    description: "Manages message threading, context tracking, and reply chains",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: create, get, list, add_message, get_context, close",
          enum: ["create", "get", "list", "add_message", "get_context", "close"]
        },
        chat_id: %{
          type: [:string, :integer],
          description: "Chat ID"
        },
        thread_id: %{
          type: :string,
          description: "Thread ID (for get/add_message/close)"
        },
        topic: %{
          type: :string,
          description: "Thread topic (for create)"
        },
        message: %{
          type: :object,
          properties: %{
            message_id: %{type: :integer},
            text: %{type: :string},
            from_user: %{type: :string},
            reply_to: %{type: :integer}
          }
        },
        max_context_messages: %{
          type: :integer,
          description: "Max messages to return in context (default: 50)"
        }
      },
      required: ["action", "chat_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        thread_id: %{type: :string},
        status: %{type: :string},
        threads: %{type: :array},
        context: %{type: :array},
        message_count: %{type: :integer}
      }
    }

  require Logger

  @threads_table :lux_telegram_threads

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    ensure_threads_table()

    case params[:action] do
      "create" -> create_thread(params, agent_name)
      "get" -> get_thread(params)
      "list" -> list_threads(params)
      "add_message" -> add_message(params)
      "get_context" -> get_context(params)
      "close" -> close_thread(params)
      _ -> {:error, "Unknown action: #{params[:action]}"}
    end
  end

  defp create_thread(params, agent_name) do
    chat_id = params[:chat_id]
    thread_id = "thread_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

    thread = %{
      id: thread_id,
      chat_id: chat_id,
      topic: params[:topic] || "Untitled Thread",
      messages: [],
      status: :active,
      created_by: agent_name,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    current_threads = get_threads_for_chat(chat_id)
    updated_threads = [thread | current_threads]
    :ets.insert(@threads_table, {{:chat, chat_id}, updated_threads})

    Logger.info("Agent #{agent_name} created thread #{thread_id} in chat #{chat_id}")

    {:ok, %{thread_id: thread_id, chat_id: chat_id, status: "created"}}
  end

  defp get_thread(params) do
    case params[:thread_id] do
      nil -> {:error, "Missing thread_id"}
      tid ->
        case find_thread(params[:chat_id], tid) do
          nil -> {:error, "Thread #{tid} not found"}
          thread -> {:ok, %{thread_id: tid, status: to_string(thread.status), message_count: length(thread.messages), topic: thread.topic}}
        end
    end
  end

  defp list_threads(params) do
    threads = get_threads_for_chat(params[:chat_id])
    summary = Enum.map(threads, fn t ->
      %{thread_id: t.id, topic: t.topic, status: to_string(t.status), message_count: length(t.messages)}
    end)
    {:ok, %{threads: summary}}
  end

  defp add_message(params) do
    case {params[:thread_id], params[:message]} do
      {nil, _} -> {:error, "Missing thread_id"}
      {_, nil} -> {:error, "Missing message"}
      {tid, message} ->
        chat_id = params[:chat_id]
        case find_thread(chat_id, tid) do
          nil -> {:error, "Thread #{tid} not found"}
          thread ->
            msg_entry = Map.merge(message, %{
              added_at: DateTime.utc_now()
            })

            updated_thread = %{thread |
              messages: thread.messages ++ [msg_entry],
              updated_at: DateTime.utc_now()
            }

            update_thread_in_store(chat_id, tid, updated_thread)

            {:ok, %{thread_id: tid, message_count: length(updated_thread.messages), status: "added"}}
        end
    end
  end

  defp get_context(params) do
    max = params[:max_context_messages] || 50

    case params[:thread_id] do
      nil -> {:error, "Missing thread_id"}
      tid ->
        case find_thread(params[:chat_id], tid) do
          nil -> {:error, "Thread #{tid} not found"}
          thread ->
            context = thread.messages |> Enum.take(-max)
            {:ok, %{thread_id: tid, context: context, message_count: length(context)}}
        end
    end
  end

  defp close_thread(params) do
    case params[:thread_id] do
      nil -> {:error, "Missing thread_id"}
      tid ->
        case find_thread(params[:chat_id], tid) do
          nil -> {:error, "Thread #{tid} not found"}
          thread ->
            updated = %{thread | status: :closed, updated_at: DateTime.utc_now()}
            update_thread_in_store(params[:chat_id], tid, updated)
            {:ok, %{thread_id: tid, status: "closed"}}
        end
    end
  end

  defp find_thread(chat_id, thread_id) do
    get_threads_for_chat(chat_id)
    |> Enum.find(&(&1.id == thread_id))
  end

  defp update_thread_in_store(chat_id, thread_id, updated_thread) do
    threads = get_threads_for_chat(chat_id)
    new_threads = Enum.map(threads, fn t ->
      if t.id == thread_id, do: updated_thread, else: t
    end)
    :ets.insert(@threads_table, {{:chat, chat_id}, new_threads})
  end

  defp get_threads_for_chat(chat_id) do
    case :ets.lookup(@threads_table, {:chat, chat_id}) do
      [{{:chat, ^chat_id}, threads}] -> threads
      [] -> []
    end
  end

  defp ensure_threads_table do
    case :ets.whereis(@threads_table) do
      :undefined -> :ets.new(@threads_table, [:named_table, :public, :set])
      _ -> :ok
    end
  end
end
