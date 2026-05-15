defmodule Lux.Prisms.Telegram.Processing.DeepLinkHandler do
  @moduledoc """
  A prism for handling Telegram deep links — parsing start parameters,
  extracting referral codes, and routing to appropriate handlers.

  ## Examples

      iex> DeepLinkHandler.handler(%{
      ...>   action: "parse",
      ...>   deep_link: "https://t.me/mybot?start=ref_abc123_campaign"
      ...> }, %{name: "Agent"})
      {:ok, %{bot: "mybot", params: %{"start" => "ref_abc123_campaign"}, ref_code: "abc123"}}
  """

  use Lux.Prism,
    name: "Handle Telegram Deep Links",
    description: "Parses and processes Telegram deep links and start parameters",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: parse, extract_referral, register_handler, list_handlers",
          enum: ["parse", "extract_referral", "register_handler", "list_handlers"]
        },
        deep_link: %{
          type: :string,
          description: "Full deep link URL or start parameter string"
        },
        start_param: %{
          type: :string,
          description: "The /start parameter value (alternative to deep_link)"
        },
        handler: %{
          type: :object,
          properties: %{
            prefix: %{type: :string, description: "Parameter prefix to match (e.g., 'ref_')"},
            name: %{type: :string, description: "Handler name"},
            description: %{type: :string}
          }
        }
      },
      required: ["action"]
    },
    output_schema: %{
      type: %{:object},
      properties: %{
        bot: %{type: :string},
        params: %{type: :object},
        ref_code: %{type: :string},
        campaign: %{type: :string},
        handlers: %{type: :array}
      }
    }

  require Logger

  @handlers_table :lux_deeplink_handlers

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    ensure_handlers_table()

    case params[:action] do
      "parse" -> parse_deep_link(params, agent_name)
      "extract_referral" -> extract_referral(params)
      "register_handler" -> register_handler(params, agent_name)
      "list_handlers" -> list_handlers()
      _ -> {:error, "Unknown action: #{params[:action]}"}
    end
  end

  defp parse_deep_link(params, agent_name) do
    input = params[:deep_link] || params[:start_param] || ""

    case input do
      "" -> {:error, "Missing deep_link or start_param"}
      link ->
        Logger.info("Agent #{agent_name} parsing deep link: #{link}")

        result = cond do
          # Full URL: https://t.me/botname?start=params
          String.starts_with?(link, "https://t.me/") ->
            parse_full_url(link)

          # Short form: just the start parameter
          true ->
            %{bot: nil, params: parse_start_param(link)}
        end

        # Try to extract referral info from params
        start_value = result.params["start"] || ""
        referral = extract_referral_from_string(start_value)

        result = Map.merge(result, %{
          ref_code: referral.ref_code,
          campaign: referral.campaign,
          raw_param: start_value
        })

        {:ok, result}
    end
  end

  defp extract_referral(params) do
    input = params[:deep_link] || params[:start_param] || ""

    case input do
      "" -> {:error, "Missing input"}
      value ->
        referral = extract_referral_from_string(value)
        {:ok, referral}
    end
  end

  defp register_handler(params, agent_name) do
    handler = params[:handler]
    case handler do
      nil -> {:error, "Missing handler parameter"}
      %{prefix: prefix, name: name} when is_binary(prefix) and is_binary(name) ->
        entry = %{
          prefix: prefix,
          name: name,
          description: handler[:description] || "",
          registered_by: agent_name,
          registered_at: DateTime.utc_now()
        }

        current = get_all_handlers()
        :ets.insert(@handlers_table, {:handlers, [entry | current]})

        {:ok, %{name: name, prefix: prefix, status: "registered"}}

      _ -> {:error, "Handler must have prefix and name"}
    end
  end

  defp list_handlers do
    {:ok, %{handlers: get_all_handlers()}}
  end

  defp parse_full_url(url) do
    uri = URI.parse(url)
    bot = String.trim_leading(uri.path || "", "/")
    query_params = URI.decode_query(uri.query || "")
    %{bot: bot, params: query_params}
  end

  defp parse_start_param(param) do
    # Format: key1_value1_key2_value2 or simple string
    if String.contains?(param, "_") do
      parts = String.split(param, "_")
      # Try to parse as key_value pairs
      case parts do
        [key, value | rest] ->
          # Check if the rest forms additional key-value pairs
          %{"start" => param, "parsed" => parse_kv_pairs(parts)}
        _ ->
          %{"start" => param}
      end
    else
      %{"start" => param}
    end
  end

  defp parse_kv_pairs([]), do: %{}
  defp parse_kv_pairs([key, value | rest]) do
    Map.put(parse_kv_pairs(rest), key, value)
  end
  defp parse_kv_pairs([_]), do: %{}

  defp extract_referral_from_string(str) do
    # Common patterns: ref_CODE, ref_CODE_CAMPAIGN
    case Regex.run(~r/ref_([a-zA-Z0-9]+)(?:_([a-zA-Z0-9_]+))?/, str) do
      [_, code] -> %{ref_code: code, campaign: nil}
      [_, code, campaign] -> %{ref_code: code, campaign: campaign}
      nil -> %{ref_code: nil, campaign: nil}
    end
  end

  defp get_all_handlers do
    case :ets.lookup(@handlers_table, :handlers) do
      [{:handlers, handlers}] -> handlers
      [] -> []
    end
  end

  defp ensure_handlers_table do
    case :ets.whereis(@handlers_table) do
      :undefined -> :ets.new(@handlers_table, [:named_table, :public, :set])
      _ -> :ok
    end
  end
end
