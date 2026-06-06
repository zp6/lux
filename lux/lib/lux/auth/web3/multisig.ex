defmodule Lux.Auth.Web3.MultiSig do
  @moduledoc """
  Multi-signature verification for Web3 authentication.

  Implements threshold-based multi-sig verification where multiple signers
  must sign the same SIWE message. A configurable threshold determines how
  many valid signatures are required.

  ## Usage

      signatures = [
        %{address: "0xabc...", signature: sig1},
        %{address: "0xdef...", signature: sig2}
      ]

      {:ok, session} = Lux.Auth.Web3.MultiSig.authenticate(
        message, signatures, 2,
        chain_id: 1, domain: "example.com"
      )
  """

  alias Lux.Auth.Web3.Signature
  alias Lux.Auth.Web3.Session
  alias Lux.Auth.Web3.Audit

  @type signature_entry :: %{
          address: String.t(),
          signature: binary()
        }

  @doc """
  Authenticates via multi-signature verification.

  Each signature is verified against the SIWE message. The number of unique
  valid signatures must meet or exceed the threshold.

  Returns `{:ok, session}` on success or `{:error, reason}` on failure.
  """
  @spec authenticate(String.t(), [signature_entry()], pos_integer(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def authenticate(message, signatures, threshold, opts \\ []) do
    chain_id = Keyword.get(opts, :chain_id, 1)
    domain = Keyword.get(opts, :domain)

    cond do
      threshold < 1 ->
        {:error, :invalid_threshold}

      length(signatures) < threshold ->
        {:error, :insufficient_signatures}

      length(signatures) != length(unique_addresses(signatures)) ->
        {:error, :duplicate_signer}

      true ->
        with :ok <- validate_siwe_message(message, opts) do
          verified = verify_signatures(message, signatures)
        valid_count = length(verified)

        if valid_count >= threshold do
          primary = hd(verified)

          {:ok, session} =
            Session.create(%{
              address: primary,
              chain_id: chain_id,
              domain: domain
            })

          Audit.log_event(:multisig_auth_success, %{
            address: primary,
            verified_count: valid_count,
            threshold: threshold,
            domain: domain,
            chain_id: chain_id
          })

          {:ok, session}
        else
          Audit.log_event(:multisig_auth_failure, %{
            verified_count: valid_count,
            threshold: threshold,
            domain: domain
          })

          {:error, :threshold_not_met}
        end
      end
    end
  end

  @doc """
  Verifies a threshold policy for a set of addresses.

  Given a list of authorized addresses and a threshold, checks if enough
  addresses from the verified set are in the authorized set.
  """
  @spec check_threshold_policy([String.t()], [String.t()], pos_integer()) ::
          {:ok, [String.t()]} | {:error, :threshold_not_met}
  def check_threshold_policy(verified_addresses, authorized_addresses, threshold) do
    authorized_set =
      authorized_addresses
      |> Enum.map(&String.downcase/1)
      |> MapSet.new()

    matched =
      verified_addresses
      |> Enum.filter(fn addr ->
        MapSet.member?(authorized_set, String.downcase(addr))
      end)

    if length(matched) >= threshold do
      {:ok, matched}
    else
      {:error, :threshold_not_met}
    end
  end

  @doc """
  Returns the number of unique valid signatures from a list of signature entries.
  """
  @spec count_valid_signatures(String.t(), [signature_entry()]) :: non_neg_integer()
  def count_valid_signatures(message, signatures) do
    message
    |> verify_signatures()
    |> length()
  end

  # --- SIWE Message Validation ---

  defp validate_siwe_message(message, opts) do
    with {:ok, parsed} <- parse_siwe_message(message) do
      nonce = Keyword.get(opts, :expected_nonce)
      domain = Keyword.get(opts, :domain)

      with :ok <- validate_nonce(parsed, nonce),
           :ok <- validate_domain(parsed, domain),
           :ok <- validate_expiration(parsed) do
        :ok
      end
    end
  end

  defp parse_siwe_message(message) when is_binary(message) do
    lines = String.split(message, "\n")

    fields =
      lines
      |> Enum.map(&String.trim/1)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] -> Map.put(acc, String.downcase(key), String.trim(value))
          _ -> acc
        end
      end)

    # Extract domain from first line (e.g., "example.com wants you to sign in")
    domain =
      case lines |> List.first() |> String.trim() |> String.split(" ", parts: 2) do
        [d | _] -> d
        _ -> nil
      end

    {:ok, Map.put(fields, "domain", domain)}
  rescue
    _ -> {:error, :invalid_siwe_message}
  end

  defp validate_nonce(_parsed, nil), do: :ok
  defp validate_nonce(%{"nonce" => nonce}, expected) when nonce == expected, do: :ok
  defp validate_nonce(_, _), do: {:error, :invalid_nonce}

  defp validate_domain(_parsed, nil), do: :ok
  defp validate_domain(%{"domain" => domain}, expected) when domain == expected, do: :ok
  defp validate_domain(_, _), do: {:error, :domain_mismatch}

  defp validate_expiration(%{"expiration-time" => expiration}) when is_binary(expiration) do
    case DateTime.from_iso8601(expiration) do
      {:ok, exp_dt, _} ->
        if DateTime.compare(DateTime.utc_now(), exp_dt) == :lt, do: :ok, else: {:error, :message_expired}

      _ ->
        {:error, :invalid_expiration_format}
    end
  end

  defp validate_expiration(_), do: :ok

  # --- Private Helpers ---

  defp verify_signatures(message, signatures) do
    signatures
    |> Enum.reduce([], fn %{address: address, signature: signature}, acc ->
      case Signature.recover_address(message, signature) do
        {:ok, recovered} ->
          if normalize(recovered) == normalize(address) do
            [normalize(recovered) | acc]
          else
            acc
          end

        {:error, _} ->
          acc
      end
    end)
    |> Enum.uniq()
  end

  defp unique_addresses(signatures) do
    signatures
    |> Enum.map(fn %{address: addr} -> normalize(addr) end)
    |> Enum.uniq()
  end

  defp normalize(address), do: String.downcase(address)
end
