defmodule Lux.Auth.Web3.TokenGate do
  @moduledoc """
  Token-gated access control for Web3 authentication.

  Provides on-chain verification of ERC-20 token balances and ERC-721 NFT
  ownership for access gating. Supports minimum balance requirements and
  collection ownership checks via RPC calls.

  ## Gate Types

    * `:erc20_balance` - Minimum ERC-20 token balance
    * `:erc721_ownership` - ERC-721 NFT collection ownership
    * `:native_balance` - Minimum native token (ETH) balance

  ## Usage

      # ERC-20 token gate: user must hold >= 100 USDC
      gate = %{
        type: :erc20_balance,
        token_address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        minimum_balance: 100,
        decimals: 6
      }
      :ok = Lux.Auth.Web3.TokenGate.check(address, gate)

      # ERC-721 NFT ownership gate
      gate = %{
        type: :erc721_ownership,
        collection_address: "0xbc4ca0eda7647a8ab7c2061c2e118a18a936f13d"
      }
      :ok = Lux.Auth.Web3.TokenGate.check(address, gate)

      # Native ETH balance gate
      gate = %{
        type: :native_balance,
        minimum_balance: 1_000_000_000_000_000_000  # 1 ETH in wei
      }
      :ok = Lux.Auth.Web3.TokenGate.check(address, gate)
  """

  @doc """
  Checks if an address meets the token gate requirements.
  """
  @spec check(String.t(), map()) :: :ok | {:error, term()}
  def check(address, %{type: :erc20_balance} = gate) do
    check_erc20_balance(address, gate)
  end

  def check(address, %{type: :erc721_ownership} = gate) do
    check_erc721_ownership(address, gate)
  end

  def check(address, %{type: :native_balance} = gate) do
    check_native_balance(address, gate)
  end

  def check(_address, %{type: type}) do
    {:error, {:unknown_gate_type, type}}
  end

  def check(_address, _gate) do
    {:error, :invalid_gate_spec}
  end

  @doc """
  Checks multiple gates. All gates must pass (AND logic).
  """
  @spec check_all(String.t(), [map()]) :: :ok | {:error, {:gate_not_met, non_neg_integer(), term()}}
  def check_all(_address, []), do: :ok

  def check_all(address, gates) do
    gates
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {gate, index}, _acc ->
      case check(address, gate) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:gate_not_met, index, reason}}}
      end
    end)
  end

  @doc """
  Checks multiple gates with OR logic. At least one gate must pass.
  """
  @spec check_any(String.t(), [map()]) :: :ok | {:error, :all_gates_failed}
  def check_any(_address, []), do: {:error, :all_gates_failed}

  def check_any(address, gates) do
    if Enum.any?(gates, fn gate -> check(address, gate) == :ok end) do
      :ok
    else
      {:error, :all_gates_failed}
    end
  end

  # --- ERC-20 Balance Check ---

  # ERC-20 balanceOf(address) selector: 0x70a08231
  @erc20_balance_selector <<112, 160, 130, 49>>

  defp check_erc20_balance(address, gate) do
    token_address = Map.fetch!(gate, :token_address)
    minimum_balance = Map.get(gate, :minimum_balance, 1)
    decimals = Map.get(gate, :decimals, 18)

    case fetch_erc20_balance(address, token_address) do
      {:ok, raw_balance} ->
        normalized = normalize_balance(raw_balance, decimals)

        if normalized >= minimum_balance do
          :ok
        else
          {:error, {:insufficient_balance, %{required: minimum_balance, actual: normalized}}}
        end

      {:error, reason} ->
        {:error, {:balance_check_failed, reason}}
    end
  end

  # --- ERC-721 Ownership Check ---

  defp check_erc721_ownership(address, gate) do
    collection_address = Map.fetch!(gate, :collection_address)
    minimum_tokens = Map.get(gate, :minimum_tokens, 1)

    case fetch_erc721_balance(address, collection_address) do
      {:ok, balance} ->
        if balance >= minimum_tokens do
          :ok
        else
          {:error, {:no_nft_found, %{collection: collection_address}}}
        end

      {:error, reason} ->
        {:error, {:ownership_check_failed, reason}}
    end
  end

  # --- Native Balance Check ---

  defp check_native_balance(address, gate) do
    minimum_balance = Map.fetch!(gate, :minimum_balance)

    case fetch_native_balance(address) do
      {:ok, balance} ->
        if balance >= minimum_balance do
          :ok
        else
          {:error, {:insufficient_balance, %{required: minimum_balance, actual: balance}}}
        end

      {:error, reason} ->
        {:error, {:balance_check_failed, reason}}
    end
  end

  # --- RPC Integration ---

  defp fetch_erc20_balance(address, token_address) do
    padded_address = pad_address(address)
    call_data = @erc20_balance_selector <> padded_address

    case eth_call(token_address, call_data) do
      {:ok, balance_bytes} when byte_size(balance_bytes) == 32 ->
        {:ok, :binary.decode_unsigned(balance_bytes)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_erc721_balance(address, collection_address) do
    padded_address = pad_address(address)
    call_data = @erc20_balance_selector <> padded_address

    case eth_call(collection_address, call_data) do
      {:ok, balance_bytes} when byte_size(balance_bytes) == 32 ->
        {:ok, :binary.decode_unsigned(balance_bytes)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_native_balance(address) do
    payload =
      Jason.encode!(%{
        jsonrpc: "2.0",
        method: "eth_getBalance",
        params: [address, "latest"],
        id: 1
      })

    case rpc_request(payload) do
      {:ok, %{"result" => "0x" <> hex}} ->
        {:ok, String.to_integer(hex, 16)}

      {:ok, %{"result" => _}} ->
        {:ok, 0}

      _ ->
        {:error, :rpc_failed}
    end
  end

  defp eth_call(to, data) do
    encoded_data = "0x" <> Base.encode16(data, case: :lower)

    payload =
      Jason.encode!(%{
        jsonrpc: "2.0",
        method: "eth_call",
        params: [%{to: to, data: encoded_data}, "latest"],
        id: 1
      })

    case rpc_request(payload) do
      {:ok, %{"result" => "0x" <> hex}} when hex != "" ->
        padded = String.pad_leading(hex, 64, "0")
        {:ok, Base.decode16!(padded, case: :lower)}

      {:ok, %{"result" => "0x"}} ->
        {:ok, <<0::size(256)>>}

      {:ok, %{"error" => error}} ->
        {:error, error}

      _ ->
        {:error, :rpc_failed}
    end
  end

  defp rpc_request(payload) do
    rpc_url = get_rpc_url()

    case :httpc.request(
           :post,
           {rpc_url, [{"Content-Type", "application/json"}], payload},
           [{:timeout, 10000}],
           []
         ) do
      {:ok, {{_, 200, _}, _, body}} ->
        Jason.decode(body)

      _ ->
        {:error, :rpc_failed}
    end
  end

  defp pad_address(address) do
    cleaned =
      address
      |> String.trim_leading("0x")
      |> String.downcase()

    padded = String.pad_leading(cleaned, 64, "0")
    Base.decode16!(padded, case: :lower)
  end

  defp normalize_balance(raw_balance, decimals) do
    raw_balance / :math.pow(10, decimals)
  end

  defp get_rpc_url do
    Application.get_env(:lux, :eth_rpc_url, "https://eth.llamarpc.com")
  end
end
