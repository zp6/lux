defmodule Lux.Native.Types.Serializer do
  @moduledoc """
  Bidirectional serialization interface between Elixir terms and Rust NIF types.

  Provides functions to serialize Elixir terms to JSON and deserialize JSON back
  to Elixir terms, going through the Rust NIF layer for high-performance
  conversion.

  ## Supported Types

  | Elixir Type           | JSON Type    | Rust Type          |
  |-----------------------|--------------|---------------------|
  | `integer()`           | number       | `i64`               |
  | `float()`             | number       | `f64`               |
  | `String.t()`          | string       | `String`            |
  | `boolean()`           | boolean      | `bool`              |
  | `nil`                 | null         | `()`                |
  | `atom()`              | string/bool  | `Atom`/`String`     |
  | `list()`              | array        | `Vec<T>`            |
  | `map()`               | object       | `HashMap<String,T>` |
  | `tuple()`             | array        | `Vec<T>`            |
  | struct (`__struct__`) | object       | `HashMap`           |

  ## Usage

      iex> Lux.Native.Types.Serializer.encode(%{"name" => "Lux", "version" => 1})
      {:ok, ~s({"name":"Lux","version":1})}

      iex> Lux.Native.Types.Serializer.decode(~s({"name":"Lux","version":1}))
      {:ok, %{"name" => "Lux", "version" => 1}}

      iex> Lux.Native.Types.Serializer.pretty(~s({"name":"Lux"}))
      {:ok, "{\\n  \\"name\\": \\"Lux\\"\\n}"}
  """

  alias Lux.Native.Rust, as: NIF

  @doc """
  Encode an Elixir term to a JSON string via Rust NIF.

  Supports maps, lists, tuples (converted to arrays), strings, numbers,
  booleans, atoms, and nil.

  ## Examples

      iex> {:ok, json} = Lux.Native.Types.Serializer.encode([1, 2, 3])
      iex> json
      "[1,2,3]"

      iex> {:ok, json} = Lux.Native.Types.Serializer.encode(%{"key" => "value"})
      iex> json
      ~s({"key":"value"})
  """
  @spec encode(term()) :: {:ok, String.t()} | {:error, term()}
  def encode(term) do
    # Prepare the term: convert atoms and tuples for proper serialization
    prepared = prepare_for_serialization(term)

    case NIF.json_encode(prepared) do
      {:ok, json} when is_binary(json) -> {:ok, json}
      {:error, reason} -> {:error, reason}
      other -> {:ok, other}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Decode a JSON string to an Elixir term via Rust NIF.

  ## Examples

      iex> {:ok, term} = Lux.Native.Types.Serializer.decode(~s([1,2,3]))
      iex> term
      [1, 2, 3]

      iex> {:ok, term} = Lux.Native.Types.Serializer.decode(~s({"key":"value"}))
      iex> term
      %{"key" => "value"}
  """
  @spec decode(String.t()) :: {:ok, term()} | {:error, term()}
  def decode(json) when is_binary(json) do
    case NIF.json_decode(json) do
      {:ok, term} -> {:ok, restore_after_deserialization(term)}
      {:error, reason} -> {:error, reason}
      other -> {:ok, other}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Pretty-print a JSON string with 2-space indentation.

  ## Examples

      iex> {:ok, pretty} = Lux.Native.Types.Serializer.pretty(~s({"a":1}))
      iex> pretty
      "{\\n  \\"a\\": 1\\n}"
  """
  @spec pretty(String.t()) :: {:ok, String.t()} | {:error, term()}
  def pretty(json) when is_binary(json) do
    case NIF.json_pretty(json) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Encode and then decode a term, testing the round-trip.

  Returns `{:ok, term}` if the round-trip preserves the value.

  ## Examples

      iex> {:ok, result} = Lux.Native.Types.Serializer.round_trip(%{"a" => 1})
      iex> result
      %{"a" => 1}
  """
  @spec round_trip(term()) :: {:ok, term()} | {:error, term()}
  def round_trip(term) do
    with {:ok, json} <- encode(term),
         {:ok, decoded} <- decode(json) do
      {:ok, decoded}
    end
  end

  @doc """
  Get the JSON type at a specific path within a JSON document.

  ## Parameters

    * `json` - JSON string
    * `path` - List of keys/indices to navigate

  ## Examples

      iex> {:ok, type} = Lux.Native.Types.Serializer.type_at(~s({"a":{"b":1}}), ["a", "b"])
      iex> type
      "number"
  """
  @spec type_at(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def type_at(json, path) when is_binary(json) and is_list(path) do
    case NIF.json_type_at(json, path) do
      {:ok, type} -> {:ok, type}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Serialize a struct to JSON, preserving the `__struct__` field.

  ## Examples

      iex> defmodule SampleStruct do; defstruct [:name, :age]; end
      iex> {:ok, json} = Lux.Native.Types.Serializer.encode_struct(%SampleStruct{name: "Test", age: 25})
      iex> is_binary(json)
      true
  """
  @spec encode_struct(struct()) :: {:ok, String.t()} | {:error, term()}
  def encode_struct(%{__struct__: module} = struct) do
    map = Map.from_struct(struct)
    map_with_module = Map.put(map, "__struct__", module)

    case NIF.json_encode(map_with_module) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Inspect a container's type, depth, and count via the Rust NIF.

  Returns `{:ok, %{type: type_name, depth: depth, count: count}}`.
  """
  @spec inspect(term()) :: {:ok, map()} | {:error, term()}
  def inspect(term) do
    case NIF.inspect_container(term) do
      {:ok, info} -> {:ok, info}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Flatten a nested list/tuple structure into a flat list via Rust NIF.
  """
  @spec flatten(term()) :: {:ok, list()} | {:error, term()}
  def flatten(term) do
    case NIF.flatten_container(term) do
      {:ok, flat} -> {:ok, flat}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # --- Private helpers ---

  # Prepare an Elixir term for serialization to Rust.
  # Converts atoms (except true/false/nil) to string representations,
  # and handles nested structures recursively.
  defp prepare_for_serialization(term) when is_map(term) do
    term
    |> Enum.map(fn {k, v} ->
      {prepare_for_serialization(k), prepare_for_serialization(v)}
    end)
    |> Map.new()
  end

  defp prepare_for_serialization(term) when is_list(term) do
    Enum.map(term, &prepare_for_serialization/1)
  end

  defp prepare_for_serialization(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&prepare_for_serialization/1)
  end

  defp prepare_for_serialization(term) when is_atom(term) do
    case term do
      true -> true
      false -> false
      nil -> nil
      atom -> ":#{atom}"
    end
  end

  defp prepare_for_serialization(term), do: term

  # Restore Elixir-specific types after deserialization from Rust.
  defp restore_after_deserialization(term) when is_map(term) do
    term
    |> Enum.map(fn {k, v} ->
      {restore_after_deserialization(k), restore_after_deserialization(v)}
    end)
    |> Map.new()
  end

  defp restore_after_deserialization(term) when is_list(term) do
    Enum.map(term, &restore_after_deserialization/1)
  end

  defp restore_after_deserialization(term), do: term
end
