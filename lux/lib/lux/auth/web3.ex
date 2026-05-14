defmodule Lux.Auth.Web3 do
  @moduledoc """
  Web3 Authentication module implementing Sign-In with Ethereum (EIP-4361).

  Provides SIWE message construction, nonce management, and authentication
  flows for verifying Ethereum wallet ownership.

  ## Example

      # Generate a nonce and build a SIWE message
      {:ok, nonce} = Lux.Auth.Web3.generate_nonce()
      message = Lux.Auth.Web3.build_siwe_message(%{
        domain: "example.com",
        address: "0x...",
        statement: "Sign in to Example",
        nonce: nonce,
        chain_id: 1
      })

      # Verify a signed message
      {:ok, session} = Lux.Auth.Web3.authenticate(message, signature)
  """

  alias Lux.Auth.Web3.Signature
  alias Lux.Auth.Web3.Session
  alias Lux.Auth.Web3.Audit

  @type siwe_params :: %{
          domain: String.t(),
          address: String.t(),
          statement: String.t(),
          nonce: String.t(),
          chain_id: non_neg_integer(),
          issued_at: String.t(),
          expiration_time: String.t() | nil,
          not_before: String.t() | nil,
          request_id: String.t() | nil,
          resources: [String.t()] | nil
        }

  @nonce_bytes 16
  @nonce_ttl_seconds 300

  @doc """
  Generates a cryptographically random nonce for SIWE authentication.

  The nonce is stored in an ETS-backed cache with a TTL of #{@nonce_ttl_seconds} seconds.
  """
  @spec generate_nonce() :: {:ok, String.t()}
  def generate_nonce do
    ensure_nonce_table()
    nonce = Base.encode16(:crypto.strong_rand_bytes(@nonce_bytes), case: :lower)
    expires_at = System.system_time(:second) + @nonce_ttl_seconds
    :ets.insert(:web3_nonces, {nonce, expires_at})
    {:ok, nonce}
  end

  @doc """
  Validates that a nonce exists and has not expired.
  Removes the nonce after validation (single-use).
  """
  @spec validate_nonce(String.t()) :: :ok | {:error, :invalid_nonce}
  def validate_nonce(nonce) do
    ensure_nonce_table()
    clean_expired_nonces()

    case :ets.lookup(:web3_nonces, nonce) do
      [{^nonce, expires_at}] ->
        :ets.delete(:web3_nonces, nonce)

        if System.system_time(:second) <= expires_at do
          :ok
        else
          {:error, :invalid_nonce}
        end

      [] ->
        {:error, :invalid_nonce}
    end
  end

  @doc """
  Builds a SIWE (EIP-4361) message string from the given parameters.

  ## Required fields

    * `:domain` - The domain requesting the sign-in
    * `:address` - The Ethereum address performing the sign-in
    * `:statement` - Human-readable statement to sign
    * `:nonce` - Random nonce for replay protection
    * `:chain_id` - The chain ID of the network

  ## Optional fields

    * `:issued_at` - ISO 8601 datetime (defaults to current time)
    * `:expiration_time` - ISO 8601 datetime
    * `:not_before` - ISO 8601 datetime
    * `:request_id` - System-specific request identifier
    * `:resources` - List of resource URIs
  """
  @spec build_siwe_message(siwe_params()) :: String.t()
  def build_siwe_message(params) do
    issued_at = params[:issued_at] || DateTime.utc_now() |> DateTime.to_iso8601()
    address = normalize_address(params.address)

    lines = [
      "#{params.domain} wants you to sign in with your Ethereum account:",
      address,
      "", # blank line
      params.statement,
      "", # blank line
      "URI: https://#{params.domain}",
      "Version: 1",
      "Chain ID: #{params.chain_id}",
      "Nonce: #{params.nonce}",
      "Issued At: #{issued_at}"
    ]

    lines = maybe_add_field(lines, "Expiration Time", params[:expiration_time])
    lines = maybe_add_field(lines, "Not Before", params[:not_before])
    lines = maybe_add_field(lines, "Request ID", params[:request_id])
    lines = maybe_add_resources(lines, params[:resources])

    Enum.join(lines, "\n")
  end

  @doc """
  Authenticates a user by verifying a signed SIWE message.

  1. Parses the SIWE message to extract fields
  2. Validates the nonce
  3. Recovers the signer address from the signature
  4. Verifies the recovered address matches the message address
  5. Creates a session if all checks pass
  6. Logs the authentication event

  Returns `{:ok, session}` on success or `{:error, reason}` on failure.
  """
  @spec authenticate(String.t(), binary()) :: {:ok, Session.t()} | {:error, term()}
  def authenticate(message, signature) do
    with {:ok, params} <- parse_siwe_message(message),
         :ok <- validate_nonce(params.nonce),
         :ok <- validate_expiration(params),
         :ok <- validate_not_before(params),
         {:ok, recovered_address} <- Signature.recover_address(message, signature),
         :ok <- verify_address(recovered_address, params.address) do
      {:ok, session} =
        Session.create(%{
          address: recovered_address,
          chain_id: params.chain_id,
          domain: params.domain
        })

      Audit.log_event(:auth_success, %{
        address: recovered_address,
        domain: params.domain,
        chain_id: params.chain_id
      })

      {:ok, session}
    else
      {:error, reason} = error ->
        address = extract_address_from_message(message)

        Audit.log_event(:auth_failure, %{
          address: address,
          reason: reason
        })

        error
    end
  end

  @doc """
  Validates an existing session token.
  """
  @spec validate_session(String.t()) :: {:ok, Session.t()} | {:error, term()}
  def validate_session(token) do
    Session.validate(token)
  end

  @doc """
  Refreshes an existing session, extending its expiry.
  """
  @spec refresh_session(String.t()) :: {:ok, Session.t()} | {:error, term()}
  def refresh_session(token) do
    Session.refresh(token)
  end

  @doc """
  Revokes a session token.
  """
  @spec revoke_session(String.t()) :: :ok
  def revoke_session(token) do
    Audit.log_event(:session_revoked, %{token_prefix: String.slice(token, 0, 8)})
    Session.revoke(token)
  end

  # --- Private Helpers ---

  defp ensure_nonce_table do
    case :ets.whereis(:web3_nonces) do
      :undefined ->
        :ets.new(:web3_nonces, [:set, :public, :named_table])

      _ref ->
        :ok
    end
  end

  defp clean_expired_nonces do
    now = System.system_time(:second)

    :ets.tab2list(:web3_nonces)
    |> Enum.each(fn {nonce, expires_at} ->
      if expires_at <= now, do: :ets.delete(:web3_nonces, nonce)
    end)
  end

  defp maybe_add_field(lines, _name, nil), do: lines
  defp maybe_add_field(lines, name, value), do: lines ++ ["#{name}: #{value}"]

  defp maybe_add_resources(lines, nil), do: lines

  defp maybe_add_resources(lines, resources) when is_list(resources) do
    resource_lines = Enum.map(resources, &"Resource: #{&1}")
    lines ++ [""] ++ resource_lines
  end

  defp normalize_address(address) do
    String.downcase(address)
  end

  defp verify_address(recovered, expected) do
    if normalize_address(recovered) == normalize_address(expected) do
      :ok
    else
      {:error, :address_mismatch}
    end
  end

  defp validate_expiration(%{expiration_time: nil}), do: :ok

  defp validate_expiration(%{expiration_time: exp}) do
    case DateTime.from_iso8601(exp) do
      {:ok, exp_dt, _offset} ->
        if DateTime.utc_now() |> DateTime.compare(exp_dt) == :lt do
          :ok
        else
          {:error, :message_expired}
        end

      _ ->
        {:error, :invalid_expiration}
    end
  end

  defp validate_not_before(%{not_before: nil}), do: :ok

  defp validate_not_before(%{not_before: nbf}) do
    case DateTime.from_iso8601(nbf) do
      {:ok, nbf_dt, _offset} ->
        if DateTime.utc_now() |> DateTime.compare(nbf_dt) == :gt do
          :ok
        else
          {:error, :message_not_yet_valid}
        end

      _ ->
        {:error, :invalid_not_before}
    end
  end

  @doc """
  Parses a SIWE message string into a structured map.
  """
  @spec parse_siwe_message(String.t()) :: {:ok, map()} | {:error, :invalid_message}
  def parse_siwe_message(message) do
    lines = String.split(message, "\n")

    with [domain_line | rest] <- lines,
         true <- String.contains?(domain_line, "wants you to sign in"),
         [address | rest2] <- rest,
         ["", statement | rest3] <- rest2,
         ["" | rest4] <- rest3 do
      params =
        rest4
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, ": ", parts: 2) do
            [key, value] -> Map.put(acc, String.downcase(key) |> String.replace(" ", "_"), value)
            _ -> acc
          end
        end)

      {:ok,
       %{
         domain: String.replace(domain_line, " wants you to sign in with your Ethereum account:", ""),
         address: String.trim(address),
         statement: statement,
         nonce: params["nonce"],
         chain_id: parse_int(params["chain_id"]),
         issued_at: params["issued_at"],
         expiration_time: params["expiration_time"],
         not_before: params["not_before"],
         request_id: params["request_id"],
         resources: parse_resources(rest4)
       }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(str), do: String.to_integer(str)

  defp parse_resources(lines) do
    resources =
      lines
      |> Enum.filter(&String.starts_with?(&1, "Resource: "))
      |> Enum.map(&String.replace(&1, "Resource: ", ""))

    if resources == [], do: nil, else: resources
  end

  defp extract_address_from_message(message) do
    case String.split(message, "\n") do
      [_, address | _] -> address
      _ -> "unknown"
    end
  end
end
