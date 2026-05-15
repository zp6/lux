defmodule Lux.Prisms.Twitter.Automation.AutoReply do
  @moduledoc """
  A prism for managing automatic reply rules to incoming tweets and mentions.

  Supports rule-based auto-reply with pattern matching, sentiment analysis
  triggers, keyword detection, and configurable reply templates.

  ## Examples

      iex> AutoReply.handler(%{
      ...>   action: "add_rule",
      ...>   pattern: "hello",
      ...>   reply_template: "Hi there! Thanks for reaching out!",
      ...>   match_type: "contains"
      ...> }, %{name: "Agent"})
      {:ok, %{rule_id: "rule_abc", action: "add_rule", status: "active"}}
  """

  use Lux.Prism,
    name: "Twitter Auto-Reply Manager",
    description: "Manages automatic reply rules for tweets and mentions",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action to perform: add_rule, remove_rule, list_rules, test_rule",
          enum: ["add_rule", "remove_rule", "list_rules", "test_rule"]
        },
        rule_id: %{
          type: :string,
          description: "ID of an existing rule (for remove_rule)"
        },
        pattern: %{
          type: :string,
          description: "Pattern to match in incoming tweets"
        },
        match_type: %{
          type: :string,
          description: "How to match: contains, regex, exact, starts_with",
          enum: ["contains", "regex", "exact", "starts_with"]
        },
        reply_template: %{
          type: :string,
          description: "Template for the auto-reply. Use {author} for mention handle."
        },
        conditions: %{
          type: :object,
          properties: %{
            min_followers: %{type: :integer, description: "Minimum follower count to trigger"},
            sentiment: %{type: :string, enum: ["positive", "negative", "neutral"]},
            language: %{type: :string, description: "ISO 639-1 language code"}
          }
        },
        enabled: %{
          type: :boolean,
          description: "Whether the rule is active (default: true)"
        },
        test_text: %{
          type: :string,
          description: "Text to test against rules (for test_rule action)"
        },
        max_replies_per_hour: %{
          type: :integer,
          description: "Rate limit for auto-replies (default: 10)"
        }
      },
      required: ["action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        action: %{type: :string},
        status: %{type: :string},
        rule_id: %{type: :string},
        rules: %{type: :array},
        matched: %{type: :boolean}
      }
    }

  require Logger

  @rules_table :lux_auto_reply_rules

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    ensure_rules_table()

    case params[:action] do
      "add_rule" ->
        add_rule(params, agent_name)

      "remove_rule" ->
        remove_rule(params)

      "list_rules" ->
        list_rules()

      "test_rule" ->
        test_rule(params)

      _ ->
        {:error, "Unknown action: #{params[:action]}"}
    end
  end

  defp add_rule(params, agent_name) do
    with {:ok, pattern} <- validate_pattern(params[:pattern]),
         {:ok, match_type} <- validate_match_type(params[:match_type]),
         {:ok, reply_template} <- validate_reply_template(params[:reply_template]) do

      rule_id = "rule_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

      rule = %{
        id: rule_id,
        pattern: pattern,
        match_type: match_type,
        reply_template: reply_template,
        conditions: params[:conditions] || %{},
        enabled: Map.get(params, :enabled, true),
        max_replies_per_hour: params[:max_replies_per_hour] || 10,
        reply_count: 0,
        last_reply_at: nil,
        created_by: agent_name,
        created_at: DateTime.utc_now()
      }

      current_rules = get_all_rules()
      :ets.insert(@rules_table, {:rules, [rule | current_rules]})

      Logger.info("Auto-reply rule #{rule_id} added by #{agent_name}")

      {:ok, %{
        action: "add_rule",
        status: "active",
        rule_id: rule_id
      }}
    end
  end

  defp remove_rule(params) do
    case params[:rule_id] do
      nil -> {:error, "Missing rule_id parameter"}
      rule_id ->
        current_rules = get_all_rules()
        filtered = Enum.reject(current_rules, &(&1.id == rule_id))
        :ets.insert(@rules_table, {:rules, filtered})

        if length(filtered) < length(current_rules) do
          {:ok, %{action: "remove_rule", status: "removed", rule_id: rule_id}}
        else
          {:error, "Rule #{rule_id} not found"}
        end
    end
  end

  defp list_rules do
    rules = get_all_rules()
    {:ok, %{action: "list_rules", status: "success", rules: rules}}
  end

  defp test_rule(params) do
    case params[:test_text] do
      nil -> {:error, "Missing test_text parameter"}
      text ->
        rules = get_all_rules() |> Enum.filter(& &1.enabled)
        matched = Enum.any?(rules, &matches_rule?(&1, text))
        {:ok, %{action: "test_rule", matched: matched}}
    end
  end

  defp matches_rule?(rule, text) do
    case rule.match_type do
      "contains" -> String.contains?(String.downcase(text), String.downcase(rule.pattern))
      "exact" -> String.downcase(text) == String.downcase(rule.pattern)
      "starts_with" -> String.starts_with?(String.downcase(text), String.downcase(rule.pattern))
      "regex" ->
        case Regex.compile(rule.pattern, "i") do
          {:ok, regex} -> Regex.match?(regex, text)
          {:error, _} -> false
        end
      _ -> false
    end
  end

  defp get_all_rules do
    case :ets.lookup(@rules_table, :rules) do
      [{:rules, rules}] -> rules
      [] -> []
    end
  end

  defp ensure_rules_table do
    case :ets.whereis(@rules_table) do
      :undefined -> :ets.new(@rules_table, [:named_table, :public, :set])
      _ -> :ok
    end
  end

  defp validate_pattern(nil), do: {:error, "Missing pattern parameter"}
  defp validate_pattern(""), do: {:error, "Pattern cannot be empty"}
  defp validate_pattern(p), do: {:ok, p}

  defp validate_match_type(nil), do: {:ok, "contains"}
  defp validate_match_type(t) when t in ["contains", "regex", "exact", "starts_with"], do: {:ok, t}
  defp validate_match_type(_), do: {:error, "Invalid match_type"}

  defp validate_reply_template(nil), do: {:error, "Missing reply_template parameter"}
  defp validate_reply_template(""), do: {:error, "Reply template cannot be empty"}
  defp validate_reply_template(t), do: {:ok, t}
end
