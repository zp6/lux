defmodule Lux.Prisms.Telegram.Management.ManageChatMember do
  @moduledoc """
  A prism for managing Telegram group/channel members.

  Supports promoting/demoting admins, restricting members, banning/unbanning users,
  and retrieving member information.

  ## Examples

      iex> ManageChatMember.handler(%{
      ...>   action: "promote",
      ...>   chat_id: -1001234567890,
      ...>   user_id: 123456789,
      ...>   can_delete_messages: true,
      ...>   can_manage_topics: true
      ...> }, %{name: "Agent"})
      {:ok, %{promoted: true, chat_id: -1001234567890, user_id: 123456789}}
  """

  use Lux.Prism,
    name: "Manage Telegram Chat Member",
    description: "Manages members, admins, and restrictions in Telegram groups",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Member management action",
          enum: ["promote", "demote", "restrict", "ban", "unban", "get_info", "get_admins", "get_member_count"]
        },
        chat_id: %{
          type: [:string, :integer],
          description: "Unique identifier for the target chat or @username"
        },
        user_id: %{
          type: :integer,
          description: "Unique identifier of the target user"
        },
        can_change_info: %{type: :boolean, description: "Can change chat info"},
        can_delete_messages: %{type: :boolean, description: "Can delete messages"},
        can_invite_users: %{type: :boolean, description: "Can invite users"},
        can_manage_topics: %{type: :boolean, description: "Can manage topics"},
        can_manage_video_chats: %{type: :boolean, description: "Can manage video chats"},
        can_pin_messages: %{type: :boolean, description: "Can pin messages"},
        can_post_messages: %{type: :boolean, description: "Can post messages (channels)"},
        can_promote_members: %{type: :boolean, description: "Can promote other members"},
        can_restrict_members: %{type: :boolean, description: "Can restrict members"},
        until_date: %{
          type: :integer,
          description: "Unix timestamp when restrictions will be lifted"
        },
        can_send_messages: %{type: :boolean},
        can_send_media_messages: %{type: :boolean},
        can_send_polls: %{type: :boolean},
        can_send_other_messages: %{type: :boolean},
        can_add_web_page_previews: %{type: :boolean},
        revoke_messages: %{type: :boolean, description: "Delete all messages from the banned user"}
      },
      required: ["action", "chat_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        action: %{type: :string},
        success: %{type: :boolean},
        chat_id: %{type: [:string, :integer]},
        user_id: %{type: :integer},
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
      Logger.info("Agent #{agent_name} member action: #{action} in chat #{chat_id}")

      case action do
        "promote" -> promote_member(chat_id, params, agent_name)
        "demote" -> demote_member(chat_id, params, agent_name)
        "restrict" -> restrict_member(chat_id, params, agent_name)
        "ban" -> ban_member(chat_id, params, agent_name)
        "unban" -> unban_member(chat_id, params, agent_name)
        "get_info" -> get_member_info(chat_id, params)
        "get_admins" -> get_chat_admins(chat_id)
        "get_member_count" -> get_member_count(chat_id)
        _ -> {:error, "Unsupported action: #{action}"}
      end
    end
  end

  defp promote_member(chat_id, params, agent_name) do
    with {:ok, user_id} <- require_user_id(params) do
      body = %{
        chat_id: chat_id,
        user_id: user_id,
        can_change_info: Map.get(params, :can_change_info, false),
        can_delete_messages: Map.get(params, :can_delete_messages, false),
        can_invite_users: Map.get(params, :can_invite_users, false),
        can_manage_topics: Map.get(params, :can_manage_topics, false),
        can_manage_video_chats: Map.get(params, :can_manage_video_chats, false),
        can_pin_messages: Map.get(params, :can_pin_messages, false),
        can_post_messages: Map.get(params, :can_post_messages, false),
        can_promote_members: Map.get(params, :can_promote_members, false),
        can_restrict_members: Map.get(params, :can_restrict_members, false)
      }

      case Client.request(:post, "/promoteChatMember", %{json: body}) do
        {:ok, %{"ok" => true}} ->
          Logger.info("Agent #{agent_name} promoted user #{user_id} in chat #{chat_id}")
          {:ok, %{action: "promote", success: true, chat_id: chat_id, user_id: user_id}}
        {:error, error} ->
          {:error, "Failed to promote member: #{inspect(error)}"}
      end
    end
  end

  defp demote_member(chat_id, params, agent_name) do
    with {:ok, user_id} <- require_user_id(params) do
      body = %{chat_id: chat_id, user_id: user_id, can_change_info: false, can_delete_messages: false,
               can_invite_users: false, can_manage_topics: false, can_pin_messages: false,
               can_promote_members: false, can_restrict_members: false}

      case Client.request(:post, "/promoteChatMember", %{json: body}) do
        {:ok, %{"ok" => true}} ->
          Logger.info("Agent #{agent_name} demoted user #{user_id} in chat #{chat_id}")
          {:ok, %{action: "demote", success: true, chat_id: chat_id, user_id: user_id}}
        {:error, error} ->
          {:error, "Failed to demote member: #{inspect(error)}"}
      end
    end
  end

  defp restrict_member(chat_id, params, agent_name) do
    with {:ok, user_id} <- require_user_id(params) do
      body = %{
        chat_id: chat_id,
        user_id: user_id,
        permissions: %{
          can_send_messages: Map.get(params, :can_send_messages, true),
          can_send_media_messages: Map.get(params, :can_send_media_messages, true),
          can_send_polls: Map.get(params, :can_send_polls, true),
          can_send_other_messages: Map.get(params, :can_send_other_messages, true),
          can_add_web_page_previews: Map.get(params, :can_add_web_page_previews, true),
          can_change_info: Map.get(params, :can_change_info, false),
          can_invite_users: Map.get(params, :can_invite_users, false),
          can_pin_messages: Map.get(params, :can_pin_messages, false),
          can_manage_topics: Map.get(params, :can_manage_topics, false)
        },
        until_date: params[:until_date]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

      case Client.request(:post, "/restrictChatMember", %{json: body}) do
        {:ok, %{"ok" => true}} ->
          Logger.info("Agent #{agent_name} restricted user #{user_id} in chat #{chat_id}")
          {:ok, %{action: "restrict", success: true, chat_id: chat_id, user_id: user_id}}
        {:error, error} ->
          {:error, "Failed to restrict member: #{inspect(error)}"}
      end
    end
  end

  defp ban_member(chat_id, params, agent_name) do
    with {:ok, user_id} <- require_user_id(params) do
      body = %{
        chat_id: chat_id,
        user_id: user_id,
        until_date: params[:until_date],
        revoke_messages: params[:revoke_messages]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

      case Client.request(:post, "/banChatMember", %{json: body}) do
        {:ok, %{"ok" => true}} ->
          Logger.info("Agent #{agent_name} banned user #{user_id} from chat #{chat_id}")
          {:ok, %{action: "ban", success: true, chat_id: chat_id, user_id: user_id}}
        {:error, error} ->
          {:error, "Failed to ban member: #{inspect(error)}"}
      end
    end
  end

  defp unban_member(chat_id, params, agent_name) do
    with {:ok, user_id} <- require_user_id(params) do
      body = %{chat_id: chat_id, user_id: user_id, only_if_banned: true}

      case Client.request(:post, "/unbanChatMember", %{json: body}) do
        {:ok, %{"ok" => true}} ->
          Logger.info("Agent #{agent_name} unbanned user #{user_id} in chat #{chat_id}")
          {:ok, %{action: "unban", success: true, chat_id: chat_id, user_id: user_id}}
        {:error, error} ->
          {:error, "Failed to unban member: #{inspect(error)}"}
      end
    end
  end

  defp get_member_info(chat_id, params) do
    with {:ok, user_id} <- require_user_id(params) do
      case Client.request(:post, "/getChatMember", %{json: %{chat_id: chat_id, user_id: user_id}}) do
        {:ok, %{"ok" => true, "result" => member_info}} ->
          {:ok, %{action: "get_info", success: true, chat_id: chat_id, user_id: user_id, details: member_info}}
        {:error, error} ->
          {:error, "Failed to get member info: #{inspect(error)}"}
      end
    end
  end

  defp get_chat_admins(chat_id) do
    case Client.request(:post, "/getChatAdministrators", %{json: %{chat_id: chat_id}}) do
      {:ok, %{"ok" => true, "result" => admins}} ->
        {:ok, %{action: "get_admins", success: true, chat_id: chat_id, details: %{"admins" => admins, "count" => length(admins)}}}
      {:error, error} ->
        {:error, "Failed to get admins: #{inspect(error)}"}
    end
  end

  defp get_member_count(chat_id) do
    case Client.request(:post, "/getChatMemberCount", %{json: %{chat_id: chat_id}}) do
      {:ok, %{"ok" => true, "result" => count}} ->
        {:ok, %{action: "get_member_count", success: true, chat_id: chat_id, details: %{"member_count" => count}}}
      {:error, error} ->
        {:error, "Failed to get member count: #{inspect(error)}"}
    end
  end

  defp validate_chat_id(params) do
    case Map.fetch(params, :chat_id) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} when is_integer(value) -> {:ok, value}
      _ -> {:error, "Missing or invalid chat_id"}
    end
  end

  defp require_user_id(params) do
    case Map.fetch(params, :user_id) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      _ -> {:error, "Missing or invalid user_id"}
    end
  end
end
