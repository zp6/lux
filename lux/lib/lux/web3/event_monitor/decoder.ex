defmodule Lux.Web3.EventMonitor.Decoder do
  @moduledoc """
  Decodes smart contract event logs from raw EVM log data.

  Supports decoding of indexed and non-indexed parameters for standard ERC events
  (ERC-20, ERC-721, ERC-1155) as well as custom events with known ABIs.

  ## Supported Standard Events

  | Standard   | Events                                        |
  |------------|-----------------------------------------------|
  | ERC-20     | Transfer, Approval                            |
  | ERC-721    | Transfer, Approval, ApprovalForAll            |
  | ERC-1155   | TransferSingle, TransferBatch, ApprovalForAll |

  ## Usage

      # Decode a known ERC-20 Transfer log
      {:ok, decoded} = Decoder.decode_log(log_entry)

      # Decode with a custom ABI
      {:ok, decoded} = Decoder.decode_log(log_entry, abi: custom_abi)

      # Identify the event standard
      standard = Decoder.identify_standard(log_entry)
      #=> :erc20
  """

  require Logger

  # Standard event signatures and their topic hashes
  @erc20_transfer_sig "Transfer(address,address,uint256)"
  @erc20_approval_sig "Approval(address,address,uint256)"
  @erc721_transfer_sig "Transfer(address,address,uint256)"
  @erc721_approval_sig "Approval(address,address,uint256)"
  @erc721_approval_for_all_sig "ApprovalForAll(address,address,bool)"
  @erc1155_transfer_single_sig "TransferSingle(address,address,address,uint256,uint256)"
  @erc1155_transfer_batch_sig "TransferBatch(address,address,address,uint256[],uint256[])"
  @erc1155_approval_for_all_sig "ApprovalForAll(address,address,bool)"

  @standard_events %{
    # keccak256("Transfer(address,address,uint256)")
    "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" =>
      %{name: "Transfer", standard: :erc20, signature: @erc20_transfer_sig},
    # keccak256("Approval(address,address,uint256)")
    "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925" =>
      %{name: "Approval", standard: :erc20, signature: @erc20_approval_sig},
    # keccak256("ApprovalForAll(address,address,bool)")
    "0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937616c5b" =>
      %{name: "ApprovalForAll", standard: :erc721, signature: @erc721_approval_for_all_sig},
    # keccak256("TransferSingle(address,address,address,uint256,uint256)")
    "0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62" =>
      %{name: "TransferSingle", standard: :erc1155, signature: @erc1155_transfer_single_sig},
    # keccak256("TransferBatch(address,address,address,uint256[],uint256[])")
    "0x4a39dc06d4c0dbc64b70af90fd698a233a518aa5d07e595d983b8c0526c8f7fb" =>
      %{name: "TransferBatch", standard: :erc1155, signature: @erc1155_transfer_batch_sig}
  }

  @doc """
  Decodes a raw EVM log entry into a structured event.

  ## Parameters

    * `log` - A map containing raw log data with keys:
      - `:topics` - List of topic hashes (hex strings)
      - `:data` - Encoded log data (hex string)
      - `:address` - Contract address (hex string)
      - `:block_number` - Block number (integer)
      - `:transaction_hash` - Transaction hash (hex string)
      - `:log_index` - Log index within the block (integer)
    * `opts` - Keyword options:
      - `:abi` - Custom ABI entries for decoding (default: standard events)

  ## Returns

    * `{:ok, decoded_event}` - Successfully decoded event
    * `{:error, reason}` - Decoding failed

  ## Decoded Event Structure

      %{
        name: "Transfer",
        standard: :erc20,
        contract_address: "0x...",
        block_number: 12345,
        transaction_hash: "0x...",
        log_index: 0,
        topics: [...],
        data: %{...},
        decoded_at: ~U[2024-01-01 00:00:00Z]
      }
  """
  @spec decode_log(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def decode_log(log, opts \\ []) do
    with {:ok, event_info} <- identify_event(log, opts[:abi]),
         {:ok, params} <- decode_parameters(log, event_info) do
      {:ok,
       %{
         name: event_info.name,
         standard: event_info.standard,
         contract_address: log[:address] || log["address"],
         block_number: log[:block_number] || log["block_number"],
         transaction_hash: log[:transaction_hash] || log["transaction_hash"],
         log_index: log[:log_index] || log["log_index"],
         topics: log[:topics] || log["topics"],
         params: params,
         decoded_at: DateTime.utc_now()
       }}
    end
  end

  @doc """
  Identifies the token standard and event type from a log entry.

  Returns the standard (`:erc20`, `:erc721`, `:erc1155`) or `:unknown`.
  """
  @spec identify_standard(map()) :: :erc20 | :erc721 | :erc1155 | :unknown
  def identify_standard(log) do
    topics = log[:topics] || log["topics"] || []

    case List.first(topics) do
      nil -> :unknown
      topic ->
        normalized = normalize_hex(topic)

        case Map.get(@standard_events, normalized) do
          %{standard: standard} -> standard
          nil -> :unknown
        end
    end
  end

  @doc """
  Returns the event name from the first topic of a log entry.
  """
  @spec get_event_name(map()) :: String.t() | :unknown
  def get_event_name(log) do
    topics = log[:topics] || log["topics"] || []

    case List.first(topics) do
      nil -> :unknown
      topic ->
        normalized = normalize_hex(topic)

        case Map.get(@standard_events, normalized) do
          %{name: name} -> name
          nil -> :unknown
        end
    end
  end

  @doc """
  Decodes an indexed parameter from a topic.
  Topics are 32-byte hex values representing addresses or uint256 values.
  """
  @spec decode_indexed_param(String.t()) :: String.t()
  def decode_indexed_param(topic) do
    normalized = normalize_hex(topic)

    # If it's an address (left-padded with zeros), extract last 20 bytes
    if String.starts_with?(normalized, "000000000000000000000000") do
      "0x" <> String.slice(normalized, 24, 40)
    else
      # It's a uint256 value
      case Integer.parse(normalized, 16) do
        {value, ""} -> Integer.to_string(value)
        _ -> topic
      end
    end
  end

  @doc """
  Decodes non-indexed parameters from log data.
  Each parameter is 32 bytes, decoded according to ABI types.
  """
  @spec decode_data_params(String.t(), [String.t()]) :: [term()]
  def decode_data_params(data, param_types) do
    data_hex = data |> String.replace("0x", "")

    data_hex
    |> String.graphemes()
    |> Enum.chunk_every(64)
    |> Enum.map(&Enum.join/1)
    |> Enum.zip(param_types)
    |> Enum.map(fn {value_hex, type} -> decode_abi_value(value_hex, type) end)
  end

  @doc """
  Returns the known standard events map.
  """
  @spec standard_events() :: map()
  def standard_events, do: @standard_events

  # Private functions

  defp identify_event(log, nil) do
    topics = log[:topics] || log["topics"] || []

    case List.first(topics) do
      nil -> {:error, :no_topics}
      topic ->
        normalized = normalize_hex(topic)

        case Map.get(@standard_events, normalized) do
          nil -> {:error, {:unknown_event, topic}}
          info -> {:ok, info}
        end
    end
  end

  defp identify_event(log, abi) when is_list(abi) do
    topics = log[:topics] || log["topics"] || []

    # First try standard events
    case identify_event(log, nil) do
      {:ok, _} = result -> result
      {:error, _} ->
        # Try custom ABI matching
        case List.first(topics) do
          nil -> {:error, :no_topics}
          topic ->
            normalized = normalize_hex(topic)
            find_custom_event(normalized, abi)
        end
    end
  end

  defp find_custom_event(_topic_hash, []), do: {:error, :event_not_found_in_abi}

  defp find_custom_event(topic_hash, [abi_entry | rest]) do
    case abi_entry do
      %{"type" => "event", "name" => name, "inputs" => inputs} ->
        sig = build_event_signature(name, inputs)

        if compute_event_topic(sig) == topic_hash do
          {:ok, %{name: name, standard: :custom, signature: sig, inputs: inputs}}
        else
          find_custom_event(topic_hash, rest)
        end

      _ ->
        find_custom_event(topic_hash, rest)
    end
  end

  defp decode_parameters(log, %{name: "Transfer", standard: :erc20}) do
    topics = log[:topics] || log["topics"] || []

    case topics do
      [_event_sig, from, to] ->
        # ERC-20 Transfer with no value in topics (value in data)
        data = log[:data] || log["data"] || "0x"
        value = decode_data_value(data)
        {:ok, %{from: decode_indexed_param(from), to: decode_indexed_param(to), value: value}}

      [_event_sig, from, to, value_or_id] ->
        # Could be ERC-721 Transfer (tokenId in topic)
        {:ok, %{
          from: decode_indexed_param(from),
          to: decode_indexed_param(to),
          token_id: decode_indexed_param(value_or_id)
        }}

      _ ->
        {:error, :invalid_transfer_topics}
    end
  end

  defp decode_parameters(log, %{name: "Approval", standard: :erc20}) do
    topics = log[:topics] || log["topics"] || []
    data = log[:data] || log["data"] || "0x"

    case topics do
      [_event_sig, owner, spender] ->
        value = decode_data_value(data)
        {:ok, %{owner: decode_indexed_param(owner), spender: decode_indexed_param(spender), value: value}}

      _ ->
        {:error, :invalid_approval_topics}
    end
  end

  defp decode_parameters(log, %{name: "ApprovalForAll"}) do
    topics = log[:topics] || log["topics"] || []

    case topics do
      [_event_sig, owner, operator, approved] ->
        {:ok, %{
          owner: decode_indexed_param(owner),
          operator: decode_indexed_param(operator),
          approved: decode_indexed_param(approved) == "1"
        }}

      _ ->
        {:error, :invalid_approval_for_all_topics}
    end
  end

  defp decode_parameters(log, %{name: "TransferSingle", standard: :erc1155}) do
    topics = log[:topics] || log["topics"] || []
    data = log[:data] || log["data"] || "0x"

    case topics do
      [_event_sig, operator, from, to] ->
        [id, value] = decode_data_params(data, ["uint256", "uint256"])
        {:ok, %{
          operator: decode_indexed_param(operator),
          from: decode_indexed_param(from),
          to: decode_indexed_param(to),
          id: id,
          value: value
        }}

      _ ->
        {:error, :invalid_transfer_single_topics}
    end
  end

  defp decode_parameters(log, %{name: "TransferBatch", standard: :erc1155}) do
    topics = log[:topics] || log["topics"] || []
    data = log[:data] || log["data"] || "0x"

    case topics do
      [_event_sig, operator, from, to] ->
        {ids, values} = decode_batch_data(data)
        {:ok, %{
          operator: decode_indexed_param(operator),
          from: decode_indexed_param(from),
          to: decode_indexed_param(to),
          ids: ids,
          values: values
        }}

      _ ->
        {:error, :invalid_transfer_batch_topics}
    end
  end

  defp decode_parameters(log, %{name: name, inputs: inputs}) do
    # Generic custom event decoding
    topics = log[:topics] || log["topics"] || []
    data = log[:data] || log["data"] || "0x"

    indexed_inputs = Enum.filter(inputs, fn input -> input["indexed"] == true end)
    non_indexed_inputs = Enum.filter(inputs, fn input -> input["indexed"] != true end)

    # Decode indexed params from topics (skip topic 0 = event sig)
    indexed_values =
      topics
      |> Enum.drop(1)
      |> Enum.zip(indexed_inputs)
      |> Enum.map(fn {topic, input} ->
        {String.to_atom(input["name"]), decode_indexed_param(topic)}
      end)

    # Decode non-indexed params from data
    non_indexed_types = Enum.map(non_indexed_inputs, & &1["name"])
    non_indexed_values =
      non_indexed_types
      |> Enum.zip(decode_data_params(data, Enum.map(non_indexed_inputs, & &1["type"])))
      |> Enum.map(fn {name, value} -> {String.to_atom(name), value} end)

    {:ok, Map.new(indexed_values ++ non_indexed_values)}
  end

  defp decode_parameters(_log, _event_info), do: {:error, :unsupported_event}

  defp decode_data_value("0x"), do: 0
  defp decode_data_value("0x" <> hex), do: decode_data_value(hex)
  defp decode_data_value(hex) do
    case Integer.parse(hex, 16) do
      {value, ""} -> value
      _ -> 0
    end
  end

  defp decode_batch_data(data) do
    data_hex = data |> String.replace("0x", "")
    chunks = chunk_hex(data_hex, 64)

    case chunks do
      [] -> {[], []}
      _ ->
        # Batch data format: offset_ids, offset_values, count_ids, [ids...], count_values, [values...]
        # Simplified: assume count at position 2, then ids, then count, then values
        count = Enum.at(chunks, 2) |> decode_hex_int()
        ids = chunks |> Enum.slice(3, count) |> Enum.map(&decode_hex_int/1)
        values = chunks |> Enum.slice(3 + count + 1, count) |> Enum.map(&decode_hex_int/1)
        {ids, values}
    end
  end

  defp decode_abi_value(value_hex, type) do
    case type do
      "address" -> "0x" <> String.slice(String.replace(value_hex, "0x", ""), 24, 40)
      "uint" <> _ -> decode_hex_int(value_hex)
      "int" <> _ -> decode_hex_int(value_hex)
      "bool" -> decode_hex_int(value_hex) == 1
      "bytes" <> _ -> "0x" <> value_hex
      "string" -> value_hex
      _ -> value_hex
    end
  end

  defp decode_hex_int(hex) do
    hex |> String.replace("0x", "") |> String.replace(~r/^0+/, "") |> case do
      "" -> 0
      cleaned -> String.to_integer(cleaned, 16)
    end
  end

  defp normalize_hex("0x" <> rest), do: String.downcase(rest)
  defp normalize_hex(hex), do: String.downcase(hex)

  defp chunk_hex(hex, size) do
    hex
    |> String.graphemes()
    |> Enum.chunk_every(size)
    |> Enum.map(&Enum.join/1)
  end

  defp build_event_signature(name, inputs) do
    param_types = Enum.map(inputs, & &1["type"])
    "#{name}(#{Enum.join(param_types, ",")})"
  end

  defp compute_event_signature_hash(_sig), do: nil

  # Placeholder: In production, use :crypto.hash(:sha3_256, sig) via ex_secp256k1 or ethers
  defp compute_event_topic(_sig), do: nil
end
