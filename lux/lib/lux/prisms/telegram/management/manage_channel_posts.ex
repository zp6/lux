defmodule Lux.Prisms.Telegram.Management.ManageChannelPosts do
  @moduledoc """
  A prism for managing Telegram channel posts.

  Supports creating, editing, deleting channel posts and
  managing post scheduling.

  ## Examples

      iex> ManageChannelPosts.handler(%{
      ...>   action: "post",
      ...>   chat_id: -1001234567890,
      ...>   text: "Breaking news update!"
      ...> }, %{name: "Agent"})
      {:ok, %{posted: true, message_id: 42, chat_id: -1001234567890}}
  """

  use Lux.Prism,
    name: "Manage Telegram Channel Posts",
    description: "Manages posts in Telegram channels",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Channel post action",
          enum: ["post", "edit", "delete", "forward", "copy"]
        },
        chat_id: %{
          type: [:string, :integer],
          description: "Channel chat ID"
        },
        text: %{
          type: :string,
          description: "Post text content"
        },
        message_id: %{
          type: :integer,
          description: "Message ID for edit/delete/forward"
        },
        parse_mode: %{
          type: :string,
          description: "Parse mode for the post",
          enum: ["Markdown", "MarkdownV2", "HTML"]
        },
        disable_notification: %{
          type: :boolean,
          description: "Send silently without notification"
        },
        from_chat_id: %{
          type: [:string, :integer],
          description: "Source chat ID for forward/copy"
        },
        to_chat_id: %{
          type: [:string, :integer],
          description: "Destination chat ID for forward/copy"
        },
        message_thread_id: %{
          type: :integer,
          description: "Forum topic ID"
        },
        protect_content: %{
          type: :boolean,
          description: "Protect content from forwarding"
        }
      },
      required: ["action", "chat_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        action: %{type: :string},
        success: %{type: :boolean},
        message_id: %{type: :integer},
        chat_id: %{type: [:string, :integer]}
      },
      required: ["action", "success"]
    }

  alias Lux.Integrations.Telegram.Client
  require Logger

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    action = params[:action]

    with {:ok, chat_id} <- validate_chat_id(params) do
      Logger.info("Agent #{agent_name} channel post action: #{action} in #{chat_id}")

      case action do
        "post" -> create_post(chat_id, params)
        "edit" -> edit_post(chat_id, params)
        "delete" -> delete_post(chat_id, params)
        "forward" -> forward_post(params)
        "copy" -> copy_post(params)
        _ -> {:error, "Unsupported action: #{action}"}
      end
    end
  end

  defp create_post(chat_id, params) do
    with {:ok, text} <- require_text(params) do
      body = %{
        chat_id: chat_id,
        text: text,
        parse_mode: params[:parse_mode],
        disable_notification: params[:disable_notification],
        protect_content: params[:protect_content],
        message_thread_id: params[:message_thread_id]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

      case Client.request(:post, "/sendMessage", %{json: body}) do
        {:ok, %{"ok" => true, "result" => %{"message_id" => msg_id}}} ->
          {:ok, %{action: "post", success: true, message_id: msg_id, chat_id: chat_id}}
        {:error, error} ->
          {:error, "Failed to create post: #{inspect(error)}"}
      end
    end
  end

  defp edit_post(chat_id, params) do
    with {:ok, text} <- require_text(params),
         {:ok, message_id} <- require_message_id(params) do
      body = %{
        chat_id: chat_id,
        message_id: message_id,
        text: text,
        parse_mode: params[:parse_mode]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

      case Client.request(:post, "/editMessageText", %{json: body}) do
        {:ok, %{"ok" => true, "result" => %{"message_id" => msg_id}}} ->
          {:ok, %{action: "edit", success: true, message_id: msg_id, chat_id: chat_id}}
        {:ok, %{"ok" => true}} ->
          {:ok, %{action: "edit", success: true, message_id: message_id, chat_id: chat_id}}
        {:error, error} ->
          {:error, "Failed to edit post: #{inspect(error)}"}
      end
    end
  end

  defp delete_post(chat_id, params) do
    with {:ok, message_id} <- require_message_id(params) do
      case Client.request(:post, "/deleteMessage", %{json: %{chat_id: chat_id, message_id: message_id}}) do
        {:ok, %{"ok" => true}} ->
          {:ok, %{action: "delete", success: true, message_id: message_id, chat_id: chat_id}}
        {:error, error} ->
          {:error, "Failed to delete post: #{inspect(error)}"}
      end
    end
  end

  defp forward_post(params) do
    with {:ok, from_chat_id} <- validate_param(params, :from_chat_id),
         {:ok, to_chat_id} <- validate_param(params, :to_chat_id),
         {:ok, message_id} <- require_message_id(params) do
      body = %{from_chat_id: from_chat_id, chat_id: to_chat_id, message_id: message_id,
               disable_notification: params[:disable_notification]}
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

      case Client.request(:post, "/forwardMessage", %{json: body}) do
        {:ok, %{"ok" => true, "result" => %{"message_id" => new_msg_id}}} ->
          {:ok, %{action: "forward", success: true, message_id: new_msg_id, chat_id: to_chat_id}}
        {:error, error} ->
          {:error, "Failed to forward post: #{inspect(error)}"}
      end
    end
  end

  defp copy_post(params) do
    with {:ok, from_chat_id} <- validate_param(params, :from_chat_id),
         {:ok, to_chat_id} <- validate_param(params, :to_chat_id),
         {:ok, message_id} <- require_message_id(params) do
      body = %{from_chat_id: from_chat_id, chat_id: to_chat_id, message_id: message_id,
               disable_notification: params[:disable_notification],
               protect_content: params[:protect_content]}
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

      case Client.request(:post, "/copyMessage", %{json: body}) do
        {:ok, %{"ok" => true, "result" => %{"message_id" => new_msg_id}}} ->
          {:ok, %{action: "copy", success: true, message_id: new_msg_id, chat_id: to_chat_id}}
        {:error, error} ->
          {:error, "Failed to copy post: #{inspect(error)}"}
      end
    end
  end

  defp validate_chat_id(params) do
    case Map.fetch(params, :chat_id) do
      {:ok, v} when is_binary(v) and v != "" -> {:ok, v}
      {:ok, v} when is_integer(v) -> {:ok, v}
      _ -> {:error, "Missing or invalid chat_id"}
    end
  end

  defp validate_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, v} when is_binary(v) and v != "" -> {:ok, v}
      {:ok, v} when is_integer(v) -> {:ok, v}
      _ -> {:error, "Missing or invalid #{key}"}
    end
  end

  defp require_text(params) do
    case Map.fetch(params, :text) do
      {:ok, v} when is_binary(v) and byte_size(v) > 0 -> {:ok, v}
      _ -> {:error, "Missing or invalid text"}
    end
  end

  defp require_message_id(params) do
    case Map.fetch(params, :message_id) do
      {:ok, v} when is_integer(v) -> {:ok, v}
      _ -> {:error, "Missing or invalid message_id"}
    end
  end
end
