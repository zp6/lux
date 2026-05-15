defmodule Lux.Prisms.Twitter.Automation.ContentCalendar do
  @moduledoc """
  A prism for managing a content calendar — organizing, scheduling, and
  tracking planned tweet content across time slots and campaigns.

  ## Examples

      iex> ContentCalendar.handler(%{
      ...>   action: "add_entry",
      ...>   title: "Product Launch",
      ...>   scheduled_at: "2025-03-01T10:00:00Z",
      ...>   content: "Excited to announce..."
      ...> }, %{name: "Agent"})
      {:ok, %{entry_id: "cal_abc", status: "scheduled"}}
  """

  use Lux.Prism,
    name: "Twitter Content Calendar",
    description: "Manages a content calendar for organizing and tracking scheduled tweets",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: add_entry, update_entry, remove_entry, list_entries, get_schedule",
          enum: ["add_entry", "update_entry", "remove_entry", "list_entries", "get_schedule"]
        },
        entry_id: %{
          type: :string,
          description: "Calendar entry ID (for update/remove)"
        },
        title: %{
          type: :string,
          description: "Title of the calendar entry"
        },
        content: %{
          type: :string,
          description: "Tweet content for this entry"
        },
        scheduled_at: %{
          type: :string,
          description: "ISO 8601 datetime for scheduled posting"
        },
        campaign: %{
          type: :string,
          description: "Campaign name to group entries"
        },
        tags: %{
          type: :array,
          items: %{type: :string},
          description: "Tags for categorization"
        },
        status: %{
          type: :string,
          description: "Entry status: draft, scheduled, posted, cancelled",
          enum: ["draft", "scheduled", "posted", "cancelled"]
        },
        date_from: %{
          type: :string,
          description: "Start date for get_schedule (ISO 8601)"
        },
        date_to: %{
          type: :string,
          description: "End date for get_schedule (ISO 8601)"
        },
        media_ids: %{
          type: :array,
          items: %{type: :string},
          description: "Media attachments for the tweet"
        }
      },
      required: ["action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        action: %{type: :string},
        entry_id: %{type: :string},
        status: %{type: :string},
        entries: %{type: :array},
        schedule: %{type: :array}
      }
    }

  require Logger

  @calendar_table :lux_content_calendar

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    ensure_calendar_table()

    case params[:action] do
      "add_entry" -> add_entry(params, agent_name)
      "update_entry" -> update_entry(params)
      "remove_entry" -> remove_entry(params)
      "list_entries" -> list_entries(params)
      "get_schedule" -> get_schedule(params)
      _ -> {:error, "Unknown action: #{params[:action]}"}
    end
  end

  defp add_entry(params, agent_name) do
    entry_id = "cal_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

    entry = %{
      id: entry_id,
      title: params[:title] || "Untitled",
      content: params[:content] || "",
      scheduled_at: params[:scheduled_at],
      campaign: params[:campaign] || "default",
      tags: params[:tags] || [],
      media_ids: params[:media_ids] || [],
      status: params[:status] || "draft",
      created_by: agent_name,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    current = get_all_entries()
    :ets.insert(@calendar_table, {:entries, [entry | current]})

    Logger.info("Calendar entry #{entry_id} added by #{agent_name}")
    {:ok, %{action: "add_entry", entry_id: entry_id, status: entry.status}}
  end

  defp update_entry(params) do
    case params[:entry_id] do
      nil -> {:error, "Missing entry_id"}
      id ->
        current = get_all_entries()

        case Enum.find(current, &(&1.id == id)) do
          nil -> {:error, "Entry #{id} not found"}
          entry ->
            updated = entry
              |> maybe_put(:title, params[:title])
              |> maybe_put(:content, params[:content])
              |> maybe_put(:scheduled_at, params[:scheduled_at])
              |> maybe_put(:campaign, params[:campaign])
              |> maybe_put(:tags, params[:tags])
              |> maybe_put(:media_ids, params[:media_ids])
              |> maybe_put(:status, params[:status])
              |> Map.put(:updated_at, DateTime.utc_now())

            new_entries = Enum.map(current, fn e -> if e.id == id, do: updated, else: e end)
            :ets.insert(@calendar_table, {:entries, new_entries})

            {:ok, %{action: "update_entry", entry_id: id, status: updated.status}}
        end
    end
  end

  defp remove_entry(params) do
    case params[:entry_id] do
      nil -> {:error, "Missing entry_id"}
      id ->
        current = get_all_entries()
        filtered = Enum.reject(current, &(&1.id == id))
        :ets.insert(@calendar_table, {:entries, filtered})
        {:ok, %{action: "remove_entry", entry_id: id, status: "removed"}}
    end
  end

  defp list_entries(params) do
    entries = get_all_entries()
    campaign = params[:campaign]
    status = params[:status]

    filtered = entries
      |> maybe_filter_by_campaign(campaign)
      |> maybe_filter_by_status(status)

    {:ok, %{action: "list_entries", entries: filtered}}
  end

  defp get_schedule(params) do
    {:ok, from_dt, _} = DateTime.from_iso8601(params[:date_from] || DateTime.utc_now() |> DateTime.to_iso8601())
    {:ok, to_dt, _} = DateTime.from_iso8601(params[:date_to] || DateTime.add(DateTime.utc_now(), 7 * 86400, :second) |> DateTime.to_iso8601())

    entries =
      get_all_entries()
      |> Enum.filter(fn entry ->
        case entry[:scheduled_at] do
          nil -> false
          sa ->
            {:ok, dt, _} = DateTime.from_iso8601(sa)
            DateTime.compare(dt, from_dt) in [:gt, :eq] and DateTime.compare(dt, to_dt) in [:lt, :eq]
        end
      end)
      |> Enum.sort_by(& &1[:scheduled_at])

    {:ok, %{action: "get_schedule", schedule: entries, from: DateTime.to_iso8601(from_dt), to: DateTime.to_iso8601(to_dt)}}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_filter_by_campaign(entries, nil), do: entries
  defp maybe_filter_by_campaign(entries, campaign), do: Enum.filter(entries, &(&1.campaign == campaign))

  defp maybe_filter_by_status(entries, nil), do: entries
  defp maybe_filter_by_status(entries, status), do: Enum.filter(entries, &(&1.status == status))

  defp get_all_entries do
    case :ets.lookup(@calendar_table, :entries) do
      [{:entries, entries}] -> entries
      [] -> []
    end
  end

  defp ensure_calendar_table do
    case :ets.whereis(@calendar_table) do
      :undefined -> :ets.new(@calendar_table, [:named_table, :public, :set])
      _ -> :ok
    end
  end
end
