defmodule Lux.Prisms.Discord.Moderation.TimeoutUser do
  @moduledoc """
  A prism for timing out (muting) a Discord guild member.

  Temporarily prevents a member from sending messages, adding reactions,
  or joining voice channels.

  ## Examples

      iex> TimeoutUser.handler(%{
      ...>   guild_id: "111222333",
      ...>   user_id: "444555666",
      ...>   duration_seconds: 3600,
      ...>   reason: "Spamming"
      ...> }, %{name: "Agent"})
      {:ok, %{timed_out: true, user_id: "444555666", guild_id: "111222333", until: 1700003600}}
  """

  use Lux.Prism,
    name: "Timeout Discord User",
    description: "Times out a Discord guild member for a specified duration",
    input_schema: %{
      type: :object,
      properties: %{
        guild_id: %{
          type: :string,
          description: "The ID of the guild",
          pattern: "^[0-9]{17,20}$"
        },
        user_id: %{
          type: :string,
          description: "The ID of the user to timeout",
          pattern: "^[0-9]{17,20}$"
        },
        duration_seconds: %{
          type: :integer,
          description: "Timeout duration in seconds (60 to 2419200 = 28 days)",
          minimum: 60,
          maximum: 2419200,
          default: 3600
        },
        reason: %{
          type: :string,
          description: "Reason for the timeout (shown in audit log)",
          maxLength: 512
        }
      },
      required: ["guild_id", "user_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        timed_out: %{type: :boolean},
        user_id: %{type: :string},
        guild_id: %{type: :string},
        communication_disabled_until: %{type: :string}
      },
      required: ["timed_out", "user_id", "guild_id"]
    }

  alias Lux.Integrations.Discord.Client
  require Logger

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"

    with {:ok, guild_id} <- validate_param(params, :guild_id),
         {:ok, user_id} <- validate_param(params, :user_id) do

      duration = params[:duration_seconds] || 3600
      until = DateTime.add(DateTime.utc_now(), duration, :second) |> DateTime.to_iso8601()

      body = %{communication_disabled_until: until}
      headers = if params[:reason], do: [{"X-Audit-Log-Reason", params[:reason]}], else: []

      Logger.info("Agent #{agent_name} timing out user #{user_id} in guild #{guild_id} for #{duration}s")

      case Client.request(:patch, "/guilds/#{guild_id}/members/#{user_id}", %{json: body, headers: headers}) do
        {:ok, %{"communication_disabled_until" => disabled_until}} ->
          Logger.info("Successfully timed out user #{user_id} until #{disabled_until}")
          {:ok, %{
            timed_out: true,
            user_id: user_id,
            guild_id: guild_id,
            communication_disabled_until: disabled_until
          }}

        {:ok, _} ->
          {:ok, %{timed_out: true, user_id: user_id, guild_id: guild_id, communication_disabled_until: until}}

        {:error, {status, %{"message" => message}}} ->
          Logger.error("Failed to timeout user: #{status} - #{message}")
          {:error, {status, message}}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp validate_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "Missing or invalid #{key}"}
    end
  end
end
