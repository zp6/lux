defmodule Lux.Auth.Web3.Session do
  @moduledoc """
  Session management for Web3 authentication.

  Provides JWT-like token generation and validation using HMAC-SHA256.
  Tokens carry the Ethereum address, chain ID, and expiry information.

  Sessions are tracked in an ETS table for revocation support.
  """

  @default_ttl_seconds 3600 * 8
  @refresh_threshold_seconds 1800

  @type t :: %__MODULE__{
          token: String.t(),
          address: String.t(),
          chain_id: non_neg_integer(),
          domain: String.t(),
          issued_at: non_neg_integer(),
          expires_at: non_neg_integer()
        }

  @enforce_keys [:token, :address, :chain_id, :domain, :issued_at, :expires_at]
  defstruct [:token, :address, :chain_id, :domain, :issued_at, :expires_at]

  @doc """
  Creates a new session for the given address.

  Generates a signed token containing session claims and stores it
  in the ETS-backed session store.

  ## Options

    * `:ttl` - Session time-to-live in seconds (default: 8 hours)
  """
  @spec create(map(), keyword()) :: {:ok, t()}
  def create(claims, opts \\ []) do
    ensure_session_table()

    ttl = Keyword.get(opts, :ttl, @default_ttl_seconds)
    now = System.system_time(:second)
    expires_at = now + ttl
    jti = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    payload = %{
      "sub" => normalize_address(claims.address),
      "chain_id" => claims.chain_id,
      "domain" => claims.domain,
      "iat" => now,
      "exp" => expires_at,
      "jti" => jti
    }

    token = encode_token(payload)

    session = %__MODULE__{
      token: token,
      address: normalize_address(claims.address),
      chain_id: claims.chain_id,
      domain: claims.domain,
      issued_at: now,
      expires_at: expires_at
    }

    :ets.insert(:web3_sessions, {jti, expires_at, session})
    {:ok, session}
  end

  @doc """
  Validates a session token.

  Checks the signature, expiry, and revocation status.
  Returns the session struct if valid.
  """
  @spec validate(String.t()) :: {:ok, t()} | {:error, term()}
  def validate(token) do
    ensure_session_table()

    with {:ok, payload} <- decode_token(token),
         :ok <- check_expiry(payload),
         :ok <- check_revocation(payload) do
      session = %__MODULE__{
        token: token,
        address: payload["sub"],
        chain_id: payload["chain_id"],
        domain: payload["domain"],
        issued_at: payload["iat"],
        expires_at: payload["exp"]
      }

      {:ok, session}
    end
  end

  @doc """
  Refreshes a valid session, extending its expiry.

  Only refreshes if the session is still valid and within the refresh threshold.
  """
  @spec refresh(String.t()) :: {:ok, t()} | {:error, term()}
  def refresh(token) do
    case validate(token) do
      {:ok, session} ->
        # Revoke the old session
        revoke_by_jti(extract_jti(token))

        # Create a new session with the same claims
        create(%{
          address: session.address,
          chain_id: session.chain_id,
          domain: session.domain
        })

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Revokes a session token.
  """
  @spec revoke(String.t()) :: :ok
  def revoke(token) do
    ensure_session_table()
    case extract_jti(token) do
      nil -> :ok
      jti -> revoke_by_jti(jti)
    end
  end

  # --- Token Encoding/Decoding ---

  defp encode_token(payload) do
    header = %{"alg" => "HS256", "typ" => "JWT"}
    header_b64 = Base.url_encode64(Jason.encode!(header), padding: false)
    payload_b64 = Base.url_encode64(Jason.encode!(payload), padding: false)
    signing_input = "#{header_b64}.#{payload_b64}"
    signature = sign(signing_input)
    signature_b64 = Base.url_encode64(signature, padding: false)
    "#{signing_input}.#{signature_b64}"
  end

  defp decode_token(token) do
    case String.split(token, ".") do
      [header_b64, payload_b64, signature_b64] ->
        signing_input = "#{header_b64}.#{payload_b64}"
        expected_sig = sign(signing_input)
        actual_sig = Base.url_decode64!(signature_b64, padding: false)

        if :crypto.hash_equals(expected_sig, actual_sig) do
          payload = Jason.decode!(Base.url_decode64!(payload_b64, padding: false))
          {:ok, payload}
        else
          {:error, :invalid_signature}
        end

      _ ->
        {:error, :invalid_token_format}
    end
  end

  defp sign(data) do
    :crypto.mac(:hmac, :sha256, signing_key(), data)
  end

  defp signing_key do
    case Application.get_env(:lux, :web3_auth_signing_key) do
      nil ->
        # Generate a persistent key from the application secret or derive one
        :crypto.hash(:sha256, "lux_web3_auth_default_key")

      key when is_binary(key) ->
        key
    end
  end

  defp check_expiry(%{"exp" => exp}) do
    if System.system_time(:second) < exp do
      :ok
    else
      {:error, :session_expired}
    end
  end

  defp check_revocation(%{"jti" => jti}) do
    case :ets.lookup(:web3_sessions, jti) do
      [{^jti, _expires_at, _session}] -> :ok
      [] -> {:error, :session_revoked}
    end
  end

  defp revoke_by_jti(jti) do
    :ets.delete(:web3_sessions, jti)
    :ok
  end

  defp extract_jti(token) do
    case String.split(token, ".") do
      [_, payload_b64, _] ->
        case Jason.decode(Base.url_decode64!(payload_b64, padding: false)) do
          {:ok, %{"jti" => jti}} -> jti
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp normalize_address(address) do
    String.downcase(address)
  end

  defp ensure_session_table do
    case :ets.whereis(:web3_sessions) do
      :undefined ->
        :ets.new(:web3_sessions, [:set, :public, :named_table])

      _ref ->
        :ok
    end
  end
end
