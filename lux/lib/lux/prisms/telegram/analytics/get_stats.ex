defmodule Lux.Prisms.Telegram.Analytics.GetStats do
  @moduledoc """
  A prism for retrieving aggregated Telegram analytics statistics.

  This prism provides a simple interface to query the analytics engine for
  metrics grouped by namespace (messages, users, commands, errors, performance, custom).

  ## Implementation Details

  - Queries `Lux.Integrations.Telegram.Analytics` for aggregated data
  - Supports single namespace or all-namespaces queries
  - Returns structured stats with totals, individual metrics, and timestamps

  ## Examples

      # Get message stats
      iex> GetStats.handler(%{namespace: "messages"}, %{name: "Agent"})
      {:ok, %{namespace: "messages", stats: %{total: 42, metrics: %{}, window: :all, computed_at: "..."}}}

      # Get all stats
      iex> GetStats.handler(%{namespace: "all"}, %{name: "Agent"})
      {:ok, %{namespace: "all", stats: %{...}}}
  """

  use Lux.Prism,
    name: "Get Telegram Analytics Stats",
    description: "Retrieves aggregated analytics statistics for the Telegram bot",
    input_schema: %{
      type: :object,
      properties: %{
        namespace: %{
          type: :string,
          description: "Namespace to query: messages, users, commands, errors, performance, custom, or all",
          enum: ["messages", "users", "commands", "errors", "performance", "custom", "all"]
        }
      },
      required: ["namespace"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        namespace: %{
          type: :string,
          description: "The queried namespace"
        },
        stats: %{
          type: :object,
          description: "Aggregated statistics"
        }
      },
      required: ["namespace", "stats"]
    }

  require Logger

  @doc """
  Handles the request to get analytics stats.
  """
  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    namespace_str = params[:namespace]

    Logger.info("Agent #{agent_name} requesting Telegram analytics for #{namespace_str}")

    result =
      if namespace_str == "all" do
        Analytics().get_all_stats()
      else
        namespace = String.to_existing_atom(namespace_str)
        Analytics().get_stats(namespace)
      end

    case result do
      {:ok, stats} ->
        Logger.info("Successfully retrieved analytics for #{namespace_str}")
        {:ok, %{namespace: namespace_str, stats: stats}}

      {:error, reason} ->
        {:error, "Failed to get analytics: #{inspect(reason)}"}
    end
  rescue
    ArgumentError ->
      {:error, "Invalid namespace: #{namespace_str}"}
  end

  # Testable indirection for Analytics module
  defp Analytics, do: Lux.Integrations.Telegram.Analytics
end
