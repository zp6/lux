defmodule Lux.Prisms.Twitter.Auth.OAuth2Flow do
  @moduledoc """
  A prism for managing Twitter OAuth 2.0 authentication flows.

  Handles the complete OAuth 2.0 PKCE flow including authorization URL generation,
  token exchange, refresh, and token state management.

  ## Examples

      iex> OAuth2Flow.handler(%{
      ...>   action: "authorize_url",
      ...>   redirect_uri: "https://example.com/callback",
      ...>   scopes: ["tweet.read", "tweet.write", "users.read"]
      ...> }, %{name: "Agent"})
      {:ok, %{url: "https://twitter.com/i/oauth2/authorize?...", state: "...", code_verifier: "..."}}
  """

  use Lux.Prism,
    name: "Twitter OAuth 2.0 Flow",
    description: "Manages Twitter OAuth 2.0 authentication with PKCE flow",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: authorize_url, exchange_code, refresh_token, get_status, revoke",
          enum: ["authorize_url", "exchange_code", "refresh_token", "get_status", "revoke"]
        },
        client_id: %{
          type: :string,
          description: "Twitter OAuth 2.0 client ID"
        },
        client_secret: %{
          type: :string,
          description: "Twitter OAuth 2.0 client secret"
        },
        redirect_uri: %{
          type: :string,
          description: "OAuth callback URL"
        },
        scopes: %{
          type: :array,
          items: %{type: :string},
          description: "OAuth scopes to request"
        },
        code: %{
          type: :string,
          description: "Authorization code from callback (for exchange_code)"
        },
        code_verifier: %{
          type: :string,
          description: "PKCE code verifier (for exchange_code)"
        },
        refresh_token: %{
          type: :string,
          description: "Refresh token (for refresh_token)"
        },
        token_set_id: %{
          type: :string,
          description: "ID of stored token set (for get_status/revoke)"
        }
      },
      required: ["action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        url: %{type: :string},
        state: %{type: :string},
        code_verifier: %{type: :string},
        access_token: %{type: :string},
        refresh_token: %{type: :string},
        expires_at: %{type: :string},
        scope: %{type: :string},
        status: %{type: :string},
        token_set_id: %{type: :string}
      }
    }

  require Logger

  @auth_url "https://twitter.com/i/oauth2/authorize"
  @token_url "https://api.twitter.com/2/oauth2/token"
  @revoke_url "https://api.twitter.com/2/oauth2/revoke"

  @token_store :lux_twitter_tokens

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    ensure_token_store()

    case params[:action] do
      "authorize_url" -> generate_authorize_url(params, agent_name)
      "exchange_code" -> exchange_code(params, agent_name)
      "refresh_token" -> refresh_token(params, agent_name)
      "get_status" -> get_status(params)
      "revoke" -> revoke_token(params, agent_name)
      _ -> {:error, "Unknown action: #{params[:action]}"}
    end
  end

  defp generate_authorize_url(params, agent_name) do
    client_id = params[:client_id] || get_config(:twitter_client_id)
    redirect_uri = params[:redirect_uri] || get_config(:twitter_redirect_uri)
    scopes = params[:scopes] || ["tweet.read", "users.read"]

    state = generate_random_string(32)
    code_verifier = generate_random_string(64)
    code_challenge = :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)

    query = URI.encode_query(%{
      response_type: "code",
      client_id: client_id,
      redirect_uri: redirect_uri,
      scope: Enum.join(scopes, " "),
      state: state,
      code_challenge: code_challenge,
      code_challenge_method: "S256"
    })

    url = "#{@auth_url}?#{query}"

    Logger.info("Agent #{agent_name} generated OAuth authorize URL")

    {:ok, %{
      url: url,
      state: state,
      code_verifier: code_verifier,
      scopes: scopes
    }}
  end

  defp exchange_code(params, agent_name) do
    client_id = params[:client_id] || get_config(:twitter_client_id)
    client_secret = params[:client_secret] || get_config(:twitter_client_secret)
    redirect_uri = params[:redirect_uri] || get_config(:twitter_redirect_uri)

    with {:ok, code} <- validate_required(params[:code], "code"),
         {:ok, code_verifier} <- validate_required(params[:code_verifier], "code_verifier") do

      Logger.info("Agent #{agent_name} exchanging OAuth code for token")

      body = URI.encode_query(%{
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        code_verifier: code_verifier
      })

      auth_header = Base.encode64("#{client_id}:#{client_secret}")

      headers = [
        {"Content-Type", "application/x-www-form-urlencoded"},
        {"Authorization", "Basic #{auth_header}"}
      ]

      case Req.post(url: @token_url, headers: headers, body: body) do
        {:ok, %{status: 200, body: token_response}} ->
          token_set_id = store_token_set(token_response)
          {:ok, %{
            token_set_id: token_set_id,
            access_token: token_response["access_token"],
            refresh_token: token_response["refresh_token"],
            expires_at: calculate_expiry(token_response["expires_in"]),
            scope: token_response["scope"],
            token_type: token_response["token_type"]
          }}

        {:ok, %{status: status, body: body}} ->
          {:error, "Token exchange failed (HTTP #{status}): #{inspect(body)}"}

        {:error, error} ->
          {:error, "Token exchange request failed: #{inspect(error)}"}
      end
    end
  end

  defp refresh_token(params, agent_name) do
    client_id = params[:client_id] || get_config(:twitter_client_id)
    client_secret = params[:client_secret] || get_config(:twitter_client_secret)

    with {:ok, refresh_token_value} <- validate_required(params[:refresh_token], "refresh_token") do

      Logger.info("Agent #{agent_name} refreshing OAuth token")

      body = URI.encode_query(%{
        grant_type: "refresh_token",
        refresh_token: refresh_token_value
      })

      auth_header = Base.encode64("#{client_id}:#{client_secret}")

      headers = [
        {"Content-Type", "application/x-www-form-urlencoded"},
        {"Authorization", "Basic #{auth_header}"}
      ]

      case Req.post(url: @token_url, headers: headers, body: body) do
        {:ok, %{status: 200, body: token_response}} ->
          {:ok, %{
            access_token: token_response["access_token"],
            refresh_token: token_response["refresh_token"],
            expires_at: calculate_expiry(token_response["expires_in"]),
            scope: token_response["scope"]
          }}

        {:ok, %{status: status, body: body}} ->
          {:error, "Token refresh failed (HTTP #{status}): #{inspect(body)}"}

        {:error, error} ->
          {:error, "Token refresh request failed: #{inspect(error)}"}
      end
    end
  end

  defp get_status(params) do
    case params[:token_set_id] do
      nil -> {:error, "Missing token_set_id"}
      id ->
        case :ets.lookup(@token_store, {:token_set, id}) do
          [{_, token_set}] ->
            expired = DateTime.compare(token_set[:expires_at], DateTime.utc_now()) == :lt
            {:ok, %{
              token_set_id: id,
              status: if(expired, do: "expired", else: "active"),
              scope: token_set[:scope],
              expires_at: DateTime.to_iso8601(token_set[:expires_at])
            }}
          [] ->
            {:error, "Token set #{id} not found"}
        end
    end
  end

  defp revoke_token(params, agent_name) do
    client_id = params[:client_id] || get_config(:twitter_client_id)

    with {:ok, token} <- validate_required(params[:refresh_token] || params[:access_token], "token") do
      Logger.info("Agent #{agent_name} revoking OAuth token")

      body = URI.encode_query(%{
        token: token,
        client_id: client_id,
        token_type_hint: "access_token"
      })

      headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

      case Req.post(url: @revoke_url, headers: headers, body: body) do
        {:ok, %{status: 200}} ->
          {:ok, %{status: "revoked"}}
        {:ok, %{status: status}} ->
          {:error, "Revoke failed (HTTP #{status})"}
        {:error, error} ->
          {:error, "Revoke request failed: #{inspect(error)}"}
      end
    end
  end

  defp store_token_set(token_response) do
    id = "ts_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

    entry = %{
      access_token: token_response["access_token"],
      refresh_token: token_response["refresh_token"],
      token_type: token_response["token_type"],
      scope: token_response["scope"],
      expires_at: calculate_expiry(token_response["expires_in"]),
      stored_at: DateTime.utc_now()
    }

    :ets.insert(@token_store, {{:token_set, id}, entry})
    id
  end

  defp calculate_expiry(expires_in) when is_integer(expires_in) do
    DateTime.add(DateTime.utc_now(), expires_in, :second)
  end
  defp calculate_expiry(_), do: DateTime.add(DateTime.utc_now(), 7200, :second)

  defp generate_random_string(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64(padding: false)
    |> String.slice(0, length)
  end

  defp get_config(key) do
    Application.get_env(:lux, key, "")
  end

  defp validate_required(nil, field), do: {:error, "Missing #{field}"}
  defp validate_required("", field), do: {:error, "#{field} cannot be empty"}
  defp validate_required(value, _field), do: {:ok, value}

  defp ensure_token_store do
    case :ets.whereis(@token_store) do
      :undefined -> :ets.new(@token_store, [:named_table, :public, :set])
      _ -> :ok
    end
  end
end
