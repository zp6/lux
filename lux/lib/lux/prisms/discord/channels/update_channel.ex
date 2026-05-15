defmodule Lux.Prisms.Discord.Channels.UpdateChannel do
  @moduledoc """
  A prism for updating Discord channel settings.

  Supports updating channel name, topic, slow mode, NSFW flag, bitrate,
  user limit, and permission overwrites.

  ## Examples

      iex> UpdateChannel.handler(%{
      ...>   channel_id: "123456789",
      ...>   name: "new-channel-name",
      ...>   topic: "Updated topic"
      ...> }, %{name: "Agent"})
      {:ok, %{updated: true, channel_id: "123456789", name: "new-channel-name"}}
  """

  use Lux.Prism,
    name: "Update Discord Channel",
    description: "Updates settings for a Discord channel",
    input_schema: %{
      type: :object,
      properties: %{
        channel_id: %{
          type: :string,
          description: "The ID of the channel to update",
          pattern: "^[0-9]{17,20}$"
        },
        name: %{
          type: :string,
          description: "New channel name (1-100 characters)",
          minLength: 1,
          maxLength: 100
        },
        topic: %{
          type: :string,
          description: "New channel topic (0-1024 characters)",
          maxLength: 1024
        },
        slowmode_seconds: %{
          type: :integer,
          description: "Slow mode delay in seconds (0-21600)",
          minimum: 0,
          maximum: 21600
        },
        nsfw: %{
          type: :boolean,
          description: "Whether the channel is NSFW"
        },
        bitrate: %{
          type: :integer,
          description: "Bitrate for voice channels (in bps)"
        },
        user_limit: %{
          type: :integer,
          description: "Max users for voice channels (0 = unlimited)"
        },
        archived: %{
          type: :boolean,
          description: "Whether to archive the channel (threads only)"
        },
        locked: %{
          type: :boolean,
          description: "Whether to lock the channel (threads only)"
        }
      },
      required: ["channel_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        updated: %{type: :boolean},
        channel_id: %{type: :string},
        name: %{type: :string}
      },
      required: ["updated", "channel_id"]
    }

  alias Lux.Integrations.Discord.Client
  require Logger

  @updatable_fields [:name, :topic, :nsfw, :bitrate, :user_limit, :archived, :locked]

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"

    with {:ok, channel_id} <- validate_param(params, :channel_id) do
      body = build_update_body(params)

      if map_size(body) == 0 do
        {:error, "No fields to update provided"}
      else
        Logger.info("Agent #{agent_name} updating channel #{channel_id}")

        case Client.request(:patch, "/channels/#{channel_id}", %{json: body}) do
          {:ok, %{"id" => ^channel_id, "name" => name}} ->
            Logger.info("Successfully updated channel #{channel_id}")
            {:ok, %{updated: true, channel_id: channel_id, name: name}}

          {:ok, %{"id" => ^channel_id}} ->
            {:ok, %{updated: true, channel_id: channel_id}}

          {:error, {status, %{"message" => message}}} ->
            Logger.error("Failed to update channel: #{status} - #{message}")
            {:error, {status, message}}

          {:error, error} ->
            {:error, error}
        end
      end
    end
  end

  defp validate_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "Missing or invalid #{key}"}
    end
  end

  defp build_update_body(params) do
    base = Map.take(params, @updatable_fields)

    # Map slowmode_seconds to rate_limit_per_user
    case Map.get(params, :slowmode_seconds) do
      nil -> base
      seconds -> Map.put(base, :rate_limit_per_user, seconds)
    end
  end
end
