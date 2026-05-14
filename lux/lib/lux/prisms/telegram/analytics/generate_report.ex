defmodule Lux.Prisms.Telegram.Analytics.GenerateReport do
  @moduledoc """
  A prism for generating comprehensive Telegram analytics reports.

  Produces a structured report covering messages, users, commands,
  errors, performance, and usage patterns for a specified time window.

  ## Implementation Details

  - Delegates to `Lux.Integrations.Telegram.Analytics.generate_report/1`
  - Supports `:hour`, `:day`, `:week`, and `:all` windows
  - Returns a full report including summary, per-namespace stats,
    performance percentiles, and hourly usage patterns

  ## Examples

      # Generate a daily report
      iex> GenerateReport.handler(%{window: "day"}, %{name: "Agent"})
      {:ok, %{report: %{summary: %{...}, messages: %{...}, ...}}}

      # Generate a weekly report
      iex> GenerateReport.handler(%{window: "week"}, %{name: "Agent"})
      {:ok, %{report: %{...}}}
  """

  use Lux.Prism,
    name: "Generate Telegram Analytics Report",
    description: "Generates a comprehensive analytics report for the Telegram bot",
    input_schema: %{
      type: :object,
      properties: %{
        window: %{
          type: :string,
          description: "Time window for the report",
          enum: ["hour", "day", "week", "all"],
          default: "day"
        }
      }
    },
    output_schema: %{
      type: :object,
      properties: %{
        report: %{
          type: :object,
          description: "The generated analytics report"
        }
      },
      required: ["report"]
    }

  require Logger

  @doc """
  Handles the request to generate an analytics report.
  """
  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    window_str = Map.get(params, :window, "day")
    window = String.to_existing_atom(window_str)

    Logger.info("Agent #{agent_name} generating Telegram analytics report for window: #{window_str}")

    case Analytics().generate_report(window) do
      {:ok, report} ->
        Logger.info("Successfully generated #{window_str} analytics report")
        {:ok, %{report: report}}

      {:error, reason} ->
        {:error, "Failed to generate report: #{inspect(reason)}"}
    end
  rescue
    ArgumentError ->
      {:error, "Invalid window: #{window_str}. Must be one of: hour, day, week, all"}
  end

  defp Analytics, do: Lux.Integrations.Telegram.Analytics
end
