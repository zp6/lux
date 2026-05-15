defmodule Lux.Prisms.Twitter.Users.UserManager do
  @moduledoc """
  A prism for managing Twitter user profiles and retrieving user data
  via the Twitter API v2.

  ## Examples

      iex> UserManager.handler(%{
      ...>   action: "get_me",
      ...> }, %{name: "Agent"})
      {:ok, %{user_id: "123", username: "mybot", name: "My Bot"}}
  """

  use Lux.Prism,
    name: "Manage Twitter User",
    description: "Manages Twitter user profiles and retrieves user data",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: get_me, get_user, get_followers, get_following, search_users, update_profile",
          enum: ["get_me", "get_user", "get_followers", "get_following", "search_users", "update_profile"]
        },
        user_id: %{
          type: :string,
          description: "Twitter user ID"
        },
        username: %{
          type: :string,
          description: "Twitter username (without @)"
        },
        query: %{
          type: :string,
          description: "Search query for user search"
        },
        max_results: %{
          type: :integer,
          description: "Maximum results per page (default: 100)"
        },
        pagination_token: %{
          type: :string,
          description: "Token for paginating results"
        },
        profile_updates: %{
          type: :object,
          properties: %{
            name: %{type: :string},
            description: %{type: :string},
            url: %{type: :string},
            location: %{type: :string}
          }
        },
        user_fields: %{
          type: :array,
          items: %{type: :string},
          description: "Additional user fields to include"
        }
      },
      required: ["action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        user: %{type: :object},
        users: %{type: :array},
        total: %{type: :integer},
        next_token: %{type: :string}
      }
    }

  alias Lux.Integrations.Twitter.Client
  require Logger

  @default_fields "id,name,username,created_at,public_metrics,verified,profile_image_url,description"

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"

    case params[:action] do
      "get_me" -> get_me(agent_name)
      "get_user" -> get_user(params, agent_name)
      "get_followers" -> get_followers(params, agent_name)
      "get_following" -> get_following(params, agent_name)
      "search_users" -> search_users(params, agent_name)
      "update_profile" -> update_profile(params, agent_name)
      _ -> {:error, "Unknown action: #{params[:action]}"}
    end
  end

  defp get_me(agent_name) do
    Logger.info("Agent #{agent_name} fetching authenticated user profile")

    case Client.request(:get, "/users/me", %{params: %{"user.fields" => @default_fields}}) do
      {:ok, %{"data" => user}} ->
        {:ok, %{user: normalize_user(user)}}

      {:error, reason} ->
        {:error, "Failed to get user profile: #{inspect(reason)}"}
    end
  end

  defp get_user(params, agent_name) do
    Logger.info("Agent #{agent_name} fetching user profile")

    result = cond do
      params[:user_id] != nil ->
        Client.request(:get, "/users/#{params[:user_id]}", %{params: %{"user.fields" => @default_fields}})

      params[:username] != nil ->
        Client.request(:get, "/users/by/username/#{params[:username]}", %{params: %{"user.fields" => @default_fields}})

      true ->
        {:error, "Provide either user_id or username"}
    end

    case result do
      {:ok, %{"data" => user}} ->
        {:ok, %{user: normalize_user(user)}}

      {:error, reason} ->
        {:error, "Failed to get user: #{inspect(reason)}"}
    end
  end

  defp get_followers(params, agent_name) do
    case params[:user_id] do
      nil -> {:error, "Missing user_id"}
        user_id ->
        Logger.info("Agent #{agent_name} fetching followers for user #{user_id}")

        query_params = %{
          "max_results" => params[:max_results] || 100,
          "user.fields" => @default_fields
        }
        query_params = maybe_add_pagination(query_params, params[:pagination_token])

        case Client.request(:get, "/users/#{user_id}/followers", %{params: query_params}) do
          {:ok, %{"data" => users, "meta" => meta}} ->
            {:ok, %{
              users: Enum.map(users, &normalize_user/1),
              total: length(users),
              next_token: meta["next_token"]
            }}

          {:ok, %{"data" => users}} ->
            {:ok, %{users: Enum.map(users, &normalize_user/1), total: length(users)}}

          {:error, reason} ->
            {:error, "Failed to get followers: #{inspect(reason)}"}
        end
    end
  end

  defp get_following(params, agent_name) do
    case params[:user_id] do
      nil -> {:error, "Missing user_id"}
      user_id ->
        Logger.info("Agent #{agent_name} fetching following for user #{user_id}")

        query_params = %{
          "max_results" => params[:max_results] || 100,
          "user.fields" => @default_fields
        }
        query_params = maybe_add_pagination(query_params, params[:pagination_token])

        case Client.request(:get, "/users/#{user_id}/following", %{params: query_params}) do
          {:ok, %{"data" => users, "meta" => meta}} ->
            {:ok, %{
              users: Enum.map(users, &normalize_user/1),
              total: length(users),
              next_token: meta["next_token"]
            }}

          {:ok, %{"data" => users}} ->
            {:ok, %{users: Enum.map(users, &normalize_user/1), total: length(users)}}

          {:error, reason} ->
            {:error, "Failed to get following: #{inspect(reason)}"}
        end
    end
  end

  defp search_users(params, agent_name) do
    case params[:query] do
      nil -> {:error, "Missing query"}
      query ->
        Logger.info("Agent #{agent_name} searching users: #{query}")

        query_params = %{
          "query" => query,
          "max_results" => params[:max_results] || 100,
          "user.fields" => @default_fields
        }
        query_params = maybe_add_pagination(query_params, params[:pagination_token])

        case Client.request(:get, "/users/search", %{params: query_params}) do
          {:ok, %{"data" => users, "meta" => meta}} ->
            {:ok, %{
              users: Enum.map(users, &normalize_user/1),
              total: length(users),
              next_token: meta["next_token"]
            }}

          {:error, reason} ->
            {:error, "Failed to search users: #{inspect(reason)}"}
        end
    end
  end

  defp update_profile(params, agent_name) do
    case params[:profile_updates] do
      nil -> {:error, "Missing profile_updates"}
      updates ->
        Logger.info("Agent #{agent_name} updating profile")

        # Get current user ID first
        case Client.request(:get, "/users/me", %{}) do
          {:ok, %{"data" => %{"id" => user_id}}} ->
            body = Map.take(updates, ["name", "description", "url", "location"])

            case Client.request(:put, "/users/#{user_id}", %{json: body}) do
              {:ok, %{"data" => updated_user}} ->
                {:ok, %{user: normalize_user(updated_user), updated: true}}

              {:error, reason} ->
                {:error, "Failed to update profile: #{inspect(reason)}"}
            end

          {:error, reason} ->
            {:error, "Failed to get current user: #{inspect(reason)}"}
        end
    end
  end

  defp normalize_user(user) do
    metrics = user["public_metrics"] || %{}

    %{
      id: user["id"],
      name: user["name"],
      username: user["username"],
      description: user["description"],
      profile_image_url: user["profile_image_url"],
      verified: user["verified"],
      created_at: user["created_at"],
      followers_count: metrics["followers_count"],
      following_count: metrics["following_count"],
      tweet_count: metrics["tweet_count"],
      listed_count: metrics["listed_count"]
    }
  end

  defp maybe_add_pagination(params, nil), do: params
  defp maybe_add_pagination(params, token), do: Map.put(params, "pagination_token", token)
end
