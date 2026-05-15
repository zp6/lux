defmodule Lux.Prisms.Twitter.Engagement.FollowManager do
  @moduledoc """
  A prism for managing follow/unfollow operations with configurable rules
  for automated audience growth and engagement optimization.

  ## Examples

      iex> FollowManager.handler(%{
      ...>   action: "follow",
      ...>   target_user_id: "123456"
      ...> }, %{name: "Agent"})
      {:ok, %{action: "follow", user_id: "123456", status: "success"}}
  """

  use Lux.Prism,
    name: "Twitter Follow Manager",
    description: "Manages follow/unfollow operations with engagement-based rules",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: follow, unfollow, auto_follow_back, prune_unfollowers, list_following",
          enum: ["follow", "unfollow", "auto_follow_back", "prune_unfollowers", "list_following"]
        },
        target_user_id: %{
          type: :string,
          description: "Twitter user ID to follow/unfollow"
        },
        follow_rules: %{
          type: :object,
          properties: %{
            min_followers: %{type: :integer},
            max_following: %{type: :integer},
            must_have_bio: %{type: :boolean},
            min_tweet_count: %{type: :integer},
            account_age_days: %{type: :integer},
            follow_ratio_max: %{type: :number}
          }
        },
        prune_rules: %{
          type: :object,
          properties: %{
            days_unfollowed: %{type: :integer, description: "Days since they unfollowed us"},
            max_to_prune: %{type: :integer, description: "Max accounts to unfollow per run"}
          }
        },
        dry_run: %{
          type: :boolean,
          description: "If true, simulate without making changes (default: false)"
        }
      },
      required: ["action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        action: %{type: :string},
        status: %{type: :string},
        user_id: %{type: :string},
        followed_count: %{type: :integer},
        unfollowed_count: %{type: :integer}
      }
    }

  alias Lux.Integrations.Twitter.Client
  require Logger

  @follow_table :lux_follow_state

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    ensure_follow_table()
    dry_run = Map.get(params, :dry_run, false)

    case params[:action] do
      "follow" -> follow_user(params, agent_name, dry_run)
      "unfollow" -> unfollow_user(params, agent_name, dry_run)
      "auto_follow_back" -> auto_follow_back(params, agent_name, dry_run)
      "prune_unfollowers" -> prune_unfollowers(params, agent_name, dry_run)
      "list_following" -> list_following()
      _ -> {:error, "Unknown action: #{params[:action]}"}
    end
  end

  defp follow_user(params, agent_name, dry_run) do
    case params[:target_user_id] do
      nil -> {:error, "Missing target_user_id"}
      user_id ->
        Logger.info("Agent #{agent_name} following user #{user_id} (dry_run: #{dry_run})")

        if dry_run do
          {:ok, %{action: "follow", user_id: user_id, status: "simulated"}}
        else
          case Client.request(:post, "/users/follow", %{json: %{target_user_id: user_id}}) do
            {:ok, response} ->
              record_follow(user_id)
              {:ok, %{action: "follow", user_id: user_id, status: "success", data: response}}

            {:error, reason} ->
              {:error, "Failed to follow user: #{inspect(reason)}"}
          end
        end
    end
  end

  defp unfollow_user(params, agent_name, dry_run) do
    case params[:target_user_id] do
      nil -> {:error, "Missing target_user_id"}
      user_id ->
        Logger.info("Agent #{agent_name} unfollowing user #{user_id} (dry_run: #{dry_run})")

        if dry_run do
          {:ok, %{action: "unfollow", user_id: user_id, status: "simulated"}}
        else
          case Client.request(:delete, "/users/#{user_id}/following", %{}) do
            {:ok, response} ->
              record_unfollow(user_id)
              {:ok, %{action: "unfollow", user_id: user_id, status: "success", data: response}}

            {:error, reason} ->
              {:error, "Failed to unfollow user: #{inspect(reason)}"}
          end
        end
    end
  end

  defp auto_follow_back(params, agent_name, dry_run) do
    rules = params[:follow_rules] || %{}
    Logger.info("Agent #{agent_name} processing auto-follow-back (dry_run: #{dry_run})")

    # Get recent followers who aren't followed back
    case Client.request(:get, "/users/me/followers", %{params: %{max_results: 50}}) do
      {:ok, %{"data" => followers}} ->
        {followed, _} =
          followers
          |> Enum.filter(&passes_rules?(&1, rules))
          |> Enum.reduce({[], dry_run}, fn follower, {acc, dr} ->
            if dr do
              {[%{user_id: follower["id"], username: follower["username"], status: "simulated"} | acc], dr}
            else
              case Client.request(:post, "/users/follow", %{json: %{target_user_id: follower["id"]}}) do
                {:ok, _} ->
                  record_follow(follower["id"])
                  {[%{user_id: follower["id"], username: follower["username"], status: "followed"} | acc], dr}
                {:error, _} ->
                  {acc, dr}
              end
            end
          end)

        {:ok, %{action: "auto_follow_back", followed_count: length(followed), followed: followed}}

      {:error, reason} ->
        {:error, "Failed to fetch followers: #{inspect(reason)}"}

      _ ->
        {:ok, %{action: "auto_follow_back", followed_count: 0, followed: []}}
    end
  end

  defp prune_unfollowers(params, agent_name, dry_run) do
    rules = params[:prune_rules] || %{}
    max_prune = rules[:max_to_prune] || 20
    Logger.info("Agent #{agent_name} pruning unfollowers (dry_run: #{dry_run})")

    prune_candidates = get_unfollowers(rules[:days_unfollowed] || 7)
    to_prune = Enum.take(prune_candidates, max_prune)

    if dry_run do
      {:ok, %{action: "prune_unfollowers", unfollowed_count: length(to_prune), candidates: to_prune, status: "simulated"}}
    else
      {unfollowed, _} =
        Enum.reduce(to_prune, {[], nil}, fn candidate, {acc, _} ->
          case Client.request(:delete, "/users/#{candidate.user_id}/following", %{}) do
            {:ok, _} ->
              record_unfollow(candidate.user_id)
              {[candidate | acc], nil}
            {:error, _} ->
              {acc, nil}
          end
        end)

      {:ok, %{action: "prune_unfollowers", unfollowed_count: length(unfollowed), unfollowed: unfollowed}}
    end
  end

  defp list_following do
    case Client.request(:get, "/users/me/following", %{params: %{max_results: 50}}) do
      {:ok, %{"data" => following}} ->
        {:ok, %{action: "list_following", count: length(following), users: following}}
      {:error, reason} ->
        {:error, "Failed to list following: #{inspect(reason)}"}
      _ ->
        {:ok, %{action: "list_following", count: 0, users: []}}
    end
  end

  defp passes_rules?(user, rules) do
    min_followers = rules[:min_followers] || 0
    max_following = rules[:max_following] || :infinity
    actual_followers = user["public_metrics"]["followers_count"] || 0
    actual_following = user["public_metrics"]["following_count"] || 0

    actual_followers >= min_followers and
      (max_following == :infinity or actual_following <= max_following)
  end

  defp record_follow(user_id) do
    current = get_follow_state()
    updated = Map.put(current, user_id, %{followed_at: DateTime.utc_now(), status: :following})
    :ets.insert(@follow_table, {:state, updated})
  end

  defp record_unfollow(user_id) do
    current = get_follow_state()
    updated = Map.update(current, user_id, %{unfollowed_at: DateTime.utc_now(), status: :unfollowed}, fn entry ->
      Map.merge(entry, %{unfollowed_at: DateTime.utc_now(), status: :unfollowed})
    end)
    :ets.insert(@follow_table, {:state, updated})
  end

  defp get_follow_state do
    case :ets.lookup(@follow_table, :state) do
      [{:state, state}] -> state
      [] -> %{}
    end
  end

  defp get_unfollowers(_days) do
    get_follow_state()
    |> Enum.filter(fn {_id, entry} -> entry[:status] == :unfollowed end)
    |> Enum.map(fn {id, entry} -> Map.put(entry, :user_id, id) end)
  end

  defp ensure_follow_table do
    case :ets.whereis(@follow_table) do
      :undefined -> :ets.new(@follow_table, [:named_table, :public, :set])
      _ -> :ok
    end
  end
end
