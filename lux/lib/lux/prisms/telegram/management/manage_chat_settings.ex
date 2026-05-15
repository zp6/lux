defmodule Lux.Prisms.Telegram.ManageChatSettings do
  @moduledoc """
  A prism for managing Telegram group/channel settings.

  Supports updating chat title, description, photo, permissions, and
  other group configuration options.

  ## Examples

      iex> ManageChatSettings.handler(%{
      ...>   action: "set_title",
      ...>   chat_id: -1001234567890,
      ...>   title: "My Awesome Group"
      ...> }, %{name: "Agent"})
      {:ok, %{updated: true, chat_id: -1001234567890, setting: "title"}}
  """

  use Lux.Prism,
    name: "Manage Telegram Chat Settings",
    description: "Manages group and channel settings in Telegram",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Settings action",
          enum: ["set_title", "set_description", "set_photo", "delete_photo",
                 "set_permissions", "get_info", "set_slow_mode", "set_sticker_set",
                 "close_forum", "open_forum", "create_invite_link", "revoke_invite_link",
                 "approve_join_request", "decline_join_request"]
        },
        chat_id: %{
          type: [:string, :integer],
          description: "Unique identifier for the target chat"
        },
        title: %{
          type: :string,
          description: "New chat title (1-128 characters)",
          minLength: 1,
          maxLength: 128
        },
        description: %{
          type: :string,
          description: "New chat description (0-255 characters)",
          maxLength: 255
        },
        photo: %{
          type: :string,
          description: "New chat photo URL"
        },
        permissions: %{
          type: :object,
          description: "Chat permissions object"
        },
        slow_mode_delay: %{
          type: :integer,
          description: "Slow mode delay in seconds (0-36000)",
          minimum: 0,
          maximum: 36000
        },
        sticker_set_name: %{
          type: :string,
          description: "Name of the sticker set to set"
        },
        invite_link: %{
          type: :string,
          description: "Invite link to revoke"
        },
        user_id: %{
          type: :integer,
          description: "User ID for join request actions"
        },
        expire_date: %{
          type: :integer,
          description: "Invite link expiration (Unix timestamp)"
        },
        member_limit: %{
          type: :integer,
          description: "Max users for invite link (1-99999)",
          minimum: 1,
          maximum: 99999
        },
        name: %{
          type: :string,
          description: "Name for the invite link"
        }
      },
      required: ["action", "chat_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        action: %{type: :string},
        success: %{type: :boolean},
        chat_id: %{type: [:string, :integer]},
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
      Logger.info("Agent #{agent_name} settings action: #{action} in chat #{chat_id}")

      case action do
        "set_title" -> set_title(chat_id, params)
        "set_description" -> set_description(chat_id, params)
        "set_photo" -> set_photo(chat_id, params)
        "delete_photo" -> delete_photo(chat_id)
        "set_permissions" -> set_permissions(chat_id, params)
        "get_info" -> get_chat_info(chat_id)
        "set_slow_mode" -> set_slow_mode(chat_id, params)
        "set_sticker_set" -> set_sticker_set(chat_id, params)
        "close_forum" -> toggle_forum(chat_id, true)
        "open_forum" -> toggle_forum(chat_id, false)
        "create_invite_link" -> create_invite_link(chat_id, params)
        "revoke_invite_link" -> revoke_invite_link(chat_id, params)
        "approve_join_request" -> handle_join_request(chat_id, params, true)
        "decline_join_request" -> handle_join_request(chat_id, params, false)
        _ -> {:error, "Unsupported action: #{action}"}
      end
    end
  end

  defp set_title(chat_id, params) do
    with {:ok, title} <- require_string_param(params, :title) do
      case Client.request(:post, "/setChatTitle", %{json: %{chat_id: chat_id, title: title}}) do
        {:ok, %{"ok" => true}} -> {:ok, %{action: "set_title", success: true, chat_id: chat_id}}
        {:error, error} -> {:error, "Failed to set title: #{inspect(error)}"}
      end
    end
  end

  defp set_description(chat_id, params) do
    description = Map.get(params, :description, "")
    case Client.request(:post, "/setChatDescription", %{json: %{chat_id: chat_id, description: description}}) do
      {:ok, %{"ok" => true}} -> {:ok, %{action: "set_description", success: true, chat_id: chat_id}}
      {:error, error} -> {:error, "Failed to set description: #{inspect(error)}"}
    end
  end

  defp set_photo(chat_id, params) do
    with {:ok, photo} <- require_string_param(params, :photo) do
      case Client.request(:post, "/setChatPhoto", %{json: %{chat_id: chat_id, photo: photo}}) do
        {:ok, %{"ok" => true}} -> {:ok, %{action: "set_photo", success: true, chat_id: chat_id}}
        {:error, error} -> {:error, "Failed to set photo: #{inspect(error)}"}
      end
    end
  end

  defp delete_photo(chat_id) do
    case Client.request(:post, "/deleteChatPhoto", %{json: %{chat_id: chat_id}}) do
      {:ok, %{"ok" => true}} -> {:ok, %{action: "delete_photo", success: true, chat_id: chat_id}}
      {:error, error} -> {:error, "Failed to delete photo: #{inspect(error)}"}
    end
  end

  defp set_permissions(chat_id, params) do
    with {:ok, permissions} <- require_param(params, :permissions) do
      body = %{chat_id: chat_id, permissions: permissions}
      case Client.request(:post, "/setChatPermissions", %{json: body}) do
        {:ok, %{"ok" => true}} -> {:ok, %{action: "set_permissions", success: true, chat_id: chat_id}}
        {:error, error} -> {:error, "Failed to set permissions: #{inspect(error)}"}
      end
    end
  end

  defp get_chat_info(chat_id) do
    case Client.request(:post, "/getChat", %{json: %{chat_id: chat_id}}) do
      {:ok, %{"ok" => true, "result" => info}} ->
        {:ok, %{action: "get_info", success: true, chat_id: chat_id, details: info}}
      {:error, error} ->
        {:error, "Failed to get chat info: #{inspect(error)}"}
    end
  end

  defp set_slow_mode(chat_id, params) do
    delay = Map.get(params, :slow_mode_delay, 0)
    case Client.request(:post, "/setChatSlowMode", %{json: %{chat_id: chat_id, slow_mode_delay: delay}}) do
      {:ok, %{"ok" => true}} -> {:ok, %{action: "set_slow_mode", success: true, chat_id: chat_id, details: %{slow_mode_delay: delay}}}
      {:error, error} -> {:error, "Failed to set slow mode: #{inspect(error)}"}
    end
  end

  defp set_sticker_set(chat_id, params) do
    with {:ok, sticker_set} <- require_string_param(params, :sticker_set_name) do
      case Client.request(:post, "/setChatStickerSet", %{json: %{chat_id: chat_id, sticker_set_name: sticker_set}}) do
        {:ok, %{"ok" => true}} -> {:ok, %{action: "set_sticker_set", success: true, chat_id: chat_id}}
        {:error, error} -> {:error, "Failed to set sticker set: #{inspect(error)}"}
      end
    end
  end

  defp toggle_forum(chat_id, is_closed) do
    case Client.request(:post, "/setChatMenuButton", %{json: %{chat_id: chat_id, is_forum: not is_closed}}) do
      {:ok, %{"ok" => true}} ->
        action = if is_closed, do: "close_forum", else: "open_forum"
        {:ok, %{action: action, success: true, chat_id: chat_id}}
      {:error, error} ->
        {:error, "Failed to toggle forum: #{inspect(error)}"}
    end
  end

  defp create_invite_link(chat_id, params) do
    body = %{chat_id: chat_id}
    |> maybe_add(:name, params[:name])
    |> maybe_add(:expire_date, params[:expire_date])
    |> maybe_add(:member_limit, params[:member_limit])

    case Client.request(:post, "/createChatInviteLink", %{json: body}) do
      {:ok, %{"ok" => true, "result" => link_info}} ->
        {:ok, %{action: "create_invite_link", success: true, chat_id: chat_id, details: link_info}}
      {:error, error} ->
        {:error, "Failed to create invite link: #{inspect(error)}"}
    end
  end

  defp revoke_invite_link(chat_id, params) do
    with {:ok, link} <- require_string_param(params, :invite_link) do
      case Client.request(:post, "/revokeChatInviteLink", %{json: %{chat_id: chat_id, invite_link: link}}) do
        {:ok, %{"ok" => true, "result" => link_info}} ->
          {:ok, %{action: "revoke_invite_link", success: true, chat_id: chat_id, details: link_info}}
        {:error, error} ->
          {:error, "Failed to revoke invite link: #{inspect(error)}"}
      end
    end
  end

  defp handle_join_request(chat_id, params, approve) do
    with {:ok, user_id} <- require_param(params, :user_id) do
      endpoint = if approve, do: "/approveChatJoinRequest", else: "/declineChatJoinRequest"
      case Client.request(:post, endpoint, %{json: %{chat_id: chat_id, user_id: user_id}}) do
        {:ok, %{"ok" => true}} ->
          action = if approve, do: "approve_join_request", else: "decline_join_request"
          {:ok, %{action: action, success: true, chat_id: chat_id, user_id: user_id}}
        {:error, error} ->
          {:error, "Failed to handle join request: #{inspect(error)}"}
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

  defp require_string_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, v} when is_binary(v) and byte_size(v) > 0 -> {:ok, v}
      _ -> {:error, "Missing or invalid #{key}"}
    end
  end

  defp require_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, v} when not is_nil(v) -> {:ok, v}
      _ -> {:error, "Missing or invalid #{key}"}
    end
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)
end
