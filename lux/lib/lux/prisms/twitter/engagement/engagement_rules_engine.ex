defmodule Lux.Prisms.Twitter.Engagement.EngagementRulesEngine do
  @moduledoc """
  A rules engine prism that evaluates incoming Twitter interactions against
  configurable engagement rules to determine automated responses.

  ## Examples

      iex> EngagementRulesEngine.handler(%{
      ...>   action: "evaluate",
      ...>   interaction: %{type: "mention", text: "Love your product!", author_id: "123"}
      ...> }, %{name: "Agent"})
      {:ok, %{matched_rules: [...], actions: [...]}}
  """

  use Lux.Prism,
    name: "Twitter Engagement Rules Engine",
    description: "Evaluates Twitter interactions against configurable engagement rules",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: evaluate, add_rule, remove_rule, list_rules",
          enum: ["evaluate", "add_rule", "remove_rule", "list_rules"]
        },
        interaction: %{
          type: :object,
          properties: %{
            type: %{type: :string, enum: ["mention", "reply", "retweet", "like", "dm", "follow"]},
            text: %{type: :string},
            author_id: %{type: :string},
            author_followers: %{type: :integer},
            tweet_id: %{type: :string},
            sentiment: %{type: :string, enum: ["positive", "negative", "neutral"]}
          }
        },
        rule: %{
          type: :object,
          properties: %{
            name: %{type: :string},
            conditions: %{
              type: :array,
              items: %{
                type: :object,
                properties: %{
                  field: %{type: :string},
                  operator: %{type: :string, enum: ["equals", "contains", "gt", "lt", "regex", "in"]},
                  value: %{type: :string}
                }
              }
            },
            action: %{
              type: :object,
              properties: %{
                type: %{type: :string, enum: ["reply", "like", "retweet", "follow", "dm", "none"]},
                template: %{type: :string},
                delay_seconds: %{type: :integer}
              }
            },
            priority: %{type: :integer},
            enabled: %{type: :boolean}
          }
        },
        rule_id: %{type: :string}
      },
      required: ["action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        matched_rules: %{type: :array},
        actions: %{type: :array},
        rule_id: %{type: :string}
      }
    }

  require Logger

  @rules_table :lux_engagement_rules

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    ensure_rules_table()

    case params[:action] do
      "evaluate" -> evaluate(params, agent_name)
      "add_rule" -> add_rule(params, agent_name)
      "remove_rule" -> remove_rule(params)
      "list_rules" -> list_rules()
      _ -> {:error, "Unknown action: #{params[:action]}"}
    end
  end

  defp evaluate(params, agent_name) do
    interaction = params[:interaction] || %{}
    Logger.info("Agent #{agent_name} evaluating interaction: #{interaction[:type]}")

    rules = get_all_rules()
             |> Enum.filter(& &1.enabled)
             |> Enum.sort_by(&(&1.priority || 0))

    matched =
      rules
      |> Enum.filter(&rule_matches?(&1, interaction))
      |> Enum.map(fn rule ->
        %{
          rule_id: rule.id,
          rule_name: rule.name,
          action: rule.action
        }
      end)

    actions =
      matched
      |> Enum.map(fn m -> m.action end)
      |> Enum.reject(&(&1.type == "none"))

    {:ok, %{matched_rules: matched, actions: actions}}
  end

  defp add_rule(params, agent_name) do
    rule_params = params[:rule]
    case validate_rule(rule_params) do
      {:ok, rule} ->
        rule_id = "eng_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

        entry = Map.merge(rule, %{
          id: rule_id,
          enabled: Map.get(rule_params, :enabled, true),
          priority: rule_params[:priority] || 50,
          created_by: agent_name,
          created_at: DateTime.utc_now()
        })

        current = get_all_rules()
        :ets.insert(@rules_table, {:rules, [entry | current]})

        {:ok, %{rule_id: rule_id, status: "active"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_rule(params) do
    case params[:rule_id] do
      nil -> {:error, "Missing rule_id"}
      id ->
        current = get_all_rules()
        filtered = Enum.reject(current, &(&1.id == id))
        :ets.insert(@rules_table, {:rules, filtered})
        {:ok, %{rule_id: id, status: "removed"}}
    end
  end

  defp list_rules do
    {:ok, %{rules: get_all_rules()}}
  end

  defp rule_matches?(rule, interaction) do
    conditions = rule[:conditions] || []

    Enum.all?(conditions, fn condition ->
      field = condition[:field]
      operator = condition[:operator]
      value = condition[:value]

      actual = get_interaction_field(interaction, field)
      evaluate_condition(actual, operator, value)
    end)
  end

  defp get_interaction_field(interaction, field) do
    case field do
      "type" -> interaction[:type]
      "text" -> interaction[:text]
      "author_id" -> interaction[:author_id]
      "author_followers" -> interaction[:author_followers]
      "sentiment" -> interaction[:sentiment]
      _ -> nil
    end
  end

  defp evaluate_condition(nil, _, _), do: false
  defp evaluate_condition(actual, "equals", value), do: to_string(actual) == value
  defp evaluate_condition(actual, "contains", value), do: String.contains?(to_string(actual), value)
  defp evaluate_condition(actual, "gt", value) when is_number(actual), do: actual > parse_number(value)
  defp evaluate_condition(actual, "lt", value) when is_number(actual), do: actual < parse_number(value)
  defp evaluate_condition(actual, "regex", value) do
    case Regex.compile(value, "i") do
      {:ok, regex} -> Regex.match?(regex, to_string(actual))
      {:error, _} -> false
    end
  end
  defp evaluate_condition(actual, "in", value) do
    values = String.split(value, ",") |> Enum.map(&String.trim/1)
    to_string(actual) in values
  end
  defp evaluate_condition(_, _, _), do: false

  defp parse_number(str) do
    case Float.parse(str) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp validate_rule(nil), do: {:error, "Missing rule parameter"}
  defp validate_rule(rule) do
    cond do
      is_nil(rule[:name]) or rule[:name] == "" -> {:error, "Rule name is required"}
      is_nil(rule[:conditions]) or rule[:conditions] == [] -> {:error, "At least one condition is required"}
      is_nil(rule[:action]) -> {:error, "Action is required"}
      true -> {:ok, rule}
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
end
