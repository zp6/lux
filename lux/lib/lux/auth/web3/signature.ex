defmodule Lux.Auth.Web3.Signature do
  @moduledoc """
  ECDSA secp256k1 signature verification and address recovery for Web3 authentication.

  Implements EIP-191 personal_sign message prefixing and recovers the signer's
  Ethereum address from a signature using the `ex_secp256k1` library.
  """

  @personal_sign_prefix "\x19Ethereum Signed Message:\n"

  @doc """
  Recovers the Ethereum address that produced the given signature for a message.

  The message is prefixed according to EIP-191 (personal_sign) before recovery.

  ## Parameters

    * `message` - The original message that was signed
    * `signature` - The 65-byte signature (r || s || v) as binary

  ## Returns

    * `{:ok, address}` - The recovered Ethereum address (0x-prefixed, checksummed)
    * `{:error, reason}` - If signature verification fails
  """
  @spec recover_address(String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def recover_address(message, signature) do
    with {:ok, hash} <- hash_message(message),
         {:ok, recovery_id} <- extract_recovery_id(signature),
         {:ok, r, s} <- extract_rs(signature),
         {:ok, public_key} <- recover_public_key(hash, r, s, recovery_id) do
      address = public_key_to_address(public_key)
      {:ok, address}
    end
  end

  @doc """
  Verifies that a signature was produced by the expected address.

  Returns `:ok` if the recovered address matches, `{:error, :signature_invalid}` otherwise.
  """
  @spec verify_signature(String.t(), binary(), String.t()) :: :ok | {:error, term()}
  def verify_signature(message, signature, expected_address) do
    case recover_address(message, signature) do
      {:ok, recovered} ->
        if normalize(recovered) == normalize(expected_address) do
          :ok
        else
          {:error, :signature_invalid}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Hashes a message using EIP-191 personal_sign prefix.

  Prepends "\\x19Ethereum Signed Message:\\n{length}" and hashes with keccak256.
  """
  @spec hash_message(String.t()) :: {:ok, binary()}
  def hash_message(message) do
    prefixed = @personal_sign_prefix <> Integer.to_string(byte_size(message)) <> message
    hash = ExSecp256k1.Hash.keccak(prefixed)
    {:ok, hash}
  end

  # --- Private Helpers ---

  defp extract_recovery_id(<<_r::binary-size(32), _s::binary-size(32), v>>) do
    # EIP-191 recovery id: v is either 27 or 28
    recovery_id = v - 27

    if recovery_id in [0, 1] do
      {:ok, recovery_id}
    else
      {:error, :invalid_recovery_id}
    end
  end

  defp extract_recovery_id(_), do: {:error, :invalid_signature_length}

  defp extract_rs(<<r::binary-size(32), s::binary-size(32), _v>>) do
    {:ok, r, s}
  end

  defp extract_rs(_), do: {:error, :invalid_signature_length}

  defp recover_public_key(hash, r, s, recovery_id) do
    case ExSecp256k1.recover(hash, r, s, recovery_id) do
      {:ok, public_key} -> {:ok, public_key}
      {:error, _reason} -> {:error, :recovery_failed}
    end
  end

  defp public_key_to_address(<<4>> <> public_key) do
    # Uncompressed public key: 0x04 + 32 bytes X + 32 bytes Y
    # Take keccak256 of the 64 bytes (X || Y), last 20 bytes is the address
    <<_::binary-size(12), address::binary-size(20)>> =
      ExSecp256k1.Hash.keccak(public_key)

    "0x" <> Base.encode16(address, case: :lower)
  end

  defp public_key_to_address(public_key) when byte_size(public_key) == 64 do
    <<_::binary-size(12), address::binary-size(20)>> =
      ExSecp256k1.Hash.keccak(public_key)

    "0x" <> Base.encode16(address, case: :lower)
  end

  defp normalize(address) do
    address
    |> String.downcase()
    |> String.trim()
  end
end
