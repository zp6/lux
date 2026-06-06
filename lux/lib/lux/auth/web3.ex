defmodule Lux.Auth.Web3 do
  @moduledoc """
  Web3 Authentication module implementing Sign-In with Ethereum (EIP-4361).

  Provides SIWE message construction, nonce management, and authentication
  flows for verifying Ethereum wallet ownership. Supports both single-sig
  and multi-sig authentication, token-gated access, and domain allowlists.

  ## Configuration

      config :lux, :siwe_domain_allowlist, ["example.com", "app.example.com"]
      config :lux, :eth_rpc_url, "https://eth.llamarpc.com"
      config :lux, :web3_auth_signing_key, "your-hmac-secret"

  ## Example

      {:ok, nonce} = Lux.Auth.Web3.generate_nonce()
      message = Lux.Auth.Web3.build_siwe_message(%{
        domain: "example.com",
        address: "0x...",
        statement: "Sign in to Example",
        nonce: nonce,
        chain_id: 1
      })
      {:ok, session} = Lux.Auth.Web3.authenticate(message, signature)
  """

  alias Lux.Auth.Web3.Signature
  alias Lux.Auth.Web3.Session
  alias Lux.Auth.Web3.Audit
  alias Lux.Auth.Web3.MultiSig
  alias Lux.Auth.Web3.TokenGate

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

  @spec generate_nonce() :: {:ok, String.t()}
  def generate_nonce do
    ensure_nonce_table()
    nonce = Base.encode16(:crypto.strong_rand_bytes(@nonce_bytes), case: :lower)
    expires_at = System.system_time(:second) + @nonce_ttl_seconds
    :ets.insert(:web3_nonces, {nonce, expires_at})
    {:ok, nonce}
  end

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
  Validates that a domain is in the configured allowlist.

      config :lux, :siwe_domain_allowlist, ["example.com", "app.example.com"]

  If no allowlist is configured, all domains are accepted (backwards compatible).
  """
  @spec validate_domain(String.t()) :: :ok | {:error, :domain_not_allowed}
  def validate_domain(domain) do
    case Application.get_env(:lux, :siwe_domain_allowlist) do
      nil ->
        :ok

      allowlist when is_list(allowlist) ->
        normalized = String.downcase(domain)

        if normalized in Enum.map(allowlist, &String.downcase/1) do
          :ok
        else
          {:error, :domain_not_allowed}
        end

      _ ->
        :ok
    end
  end

  @spec build_siwe_message(siwe_params()) :: String.t()
  def build_siwe_message(params) do
    issued_at = params[:issued_at] || DateTime.utc_now() |> DateTime.to_iso8601()
    address = normalize_address(params.address)

    lines = [
      "#{params.domain} wants you to sign in with your Ethereum account:",
      address,
      "",
      params.statement,
      "",
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
  2. Validates the domain against the configured allowlist
  3. Validates the nonce
  4. Recovers the signer address from the signature
  5. Verifies the recovered address matches the message address
  6. Creates a session if all checks pass
  7. Logs the authentication event
  """
  @spec authenticate(String.t(), binary()) :: {:ok, Session.t()} | {:error, term()}
  def authenticate(message, signature) do
    with {:ok, params} <- parse_siwe_message(message),
         :ok <- validate_domain(params.domain),
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
  Authenticates a user via multi-signature verification.
  """
  @spec authenticate_multisig(String.t(), [map()], pos_integer(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def authenticate_multisig(message, signatures, threshold, opts \\ []) do
    MultiSig.authenticate(message, signatures, threshold, opts)
  end

  @doc """
  Checks token-gated access for an address.
  """
  @spec check_token_gate(String.t(), map()) :: :ok | {:error, term()}
  def check_token_gate(address, gate_spec) do
    TokenGate.check(address, gate_spec)
  end

  @spec validate_session(String.t()) :: {:ok, Session.t()} | {:error, term()}
  def validate_session(token) do
    Session.validate(token)
  end

  @doc """
  Refreshes an existing session, extending its expiry.
  """
  @spec refresh_session(String.t()) :: {:ok, Session.t()} | {:error, term()}
  def refresh_session(token) do
    case Session.refresh(token) do
      {:ok, _new_session} = result ->
        Audit.log_event(:session_refreshed, %{token_prefix: String.slice(token, 0, 8)})
        result

      {:error, _} = error ->
        error
    end
  end

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
