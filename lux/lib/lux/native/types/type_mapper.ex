defmodule Lux.Native.Types.TypeMapper do
  @moduledoc """
  Type mapping registry between Elixir types and Rust types.

  Provides a central registry for bidirectional type mappings, enabling
  consistent conversion across the NIF boundary.

  ## Built-in Mappings

  | Elixir Type     | Rust Type              | JSON Type  |
  |-----------------|------------------------|------------|
  | `integer()`     | `i64`                  | number     |
  | `float()`       | `f64`                  | number     |
  | `String.t()`    | `String`               | string     |
  | `boolean()`     | `bool`                 | boolean    |
  | `nil`           | `()` (unit)            | null       |
  | `atom()`        | `Atom` / `String`      | string     |
  | `list()`        | `Vec<T>`               | array      |
  | `map()`         | `HashMap<String, T>`   | object     |
  | `tuple()`       | `(T1, T2, ...)`        | array      |
  | struct          | `CustomTypeDef`        | object     |

  ## Usage

      iex> Lux.Native.Types.TypeMapper.elixir_to_rust(:integer)
      "i64"

      iex> Lux.Native.Types.TypeMapper.rust_to_elixir("String")
      "String.t()"

      iex> Lux.Native.Types.TypeMapper.register_mapping("MyApp.User", "User", [
      ...>   %{name: "email", elixir_type: "String.t()", rust_type: "String"},
      ...>   %{name: "age", elixir_type: "integer()", rust_type: "i64"}
      ...> ])
      :ok
  """

  @builtin_mappings %{
    # Elixir type => Rust type
    "integer" => "i64",
    "float" => "f64",
    "String.t()" => "String",
    "binary" => "String",
    "boolean" => "bool",
    "nil" => "()",
    "atom" => "Atom",
    "list" => "Vec<T>",
    "map" => "HashMap<String, T>",
    "tuple" => "(T1, T2, ...)",
    "term" => "Term"
  }

  @rust_to_elixir %{
    "i64" => "integer",
    "f64" => "float",
    "String" => "String.t()",
    "bool" => "boolean",
    "()" => "nil",
    "Atom" => "atom",
    "Vec<T>" => "list",
    "HashMap<String, T>" => "map"
  }

  @doc """
  Get all built-in type mappings.
  """
  @spec builtin_mappings() :: %{String.t() => String.t()}
  def builtin_mappings, do: @builtin_mappings

  @doc """
  Convert an Elixir type name to its Rust equivalent.
  """
  @spec elixir_to_rust(atom() | String.t()) :: String.t() | nil
  def elixir_to_rust(type) when is_atom(type) do
    @builtin_mappings[Atom.to_string(type)]
  end

  def elixir_to_rust(type) when is_binary(type) do
    @builtin_mappings[type]
  end

  @doc """
  Convert a Rust type name to its Elixir equivalent.
  """
  @spec rust_to_elixir(String.t()) :: String.t() | nil
  def rust_to_elixir(rust_type) do
    @rust_to_elixir[rust_type]
  end

  @doc """
  Get the JSON type for an Elixir type.
  """
  @spec elixir_to_json(atom() | String.t()) :: String.t() | nil
  def elixir_to_json(:integer), do: "number"
  def elixir_to_json(:float), do: "number"
  def elixir_to_json(:string), do: "string"
  def elixir_to_json("String.t()"), do: "string"
  def elixir_to_json(:boolean), do: "boolean"
  def elixir_to_json(:map), do: "object"
  def elixir_to_json(:list), do: "array"
  def elixir_to_json(:tuple), do: "array"
  def elixir_to_json(:nil), do: "null"
  def elixir_to_json(:atom), do: "string"
  def elixir_to_json(type) when is_binary(type), do: elixir_to_json(String.to_atom(type))
  def elixir_to_json(_), do: nil

  @doc """
  Detect the Elixir type of a value.
  """
  @spec detect_type(term()) :: atom()
  def detect_type(value) do
    cond do
      is_integer(value) -> :integer
      is_float(value) -> :float
      is_boolean(value) -> :boolean
      is_binary(value) -> :string
      is_atom(value) -> :atom
      is_list(value) -> :list
      is_map(value) and Map.has_key?(value, :__struct__) -> :struct
      is_map(value) -> :map
      is_tuple(value) -> :tuple
      is_nil(value) -> :nil
      is_function(value) -> :function
      is_pid(value) -> :pid
      is_reference(value) -> :reference
      is_port(value) -> :port
      true -> :unknown
    end
  end

  @doc """
  Check if a type is a primitive (non-container) type.
  """
  @spec primitive?(atom()) :: boolean()
  def primitive?(:integer), do: true
  def primitive?(:float), do: true
  def primitive?(:boolean), do: true
  def primitive?(:string), do: true
  def primitive?(:atom), do: true
  def primitive?(:nil), do: true
  def primitive?(_), do: false

  @doc """
  Check if a type is a container type.
  """
  @spec container?(atom()) :: boolean()
  def container?(:list), do: true
  def container?(:map), do: true
  def container?(:tuple), do: true
  def container?(:struct), do: true
  def container?(_), do: false

  # Custom type registry (agent-backed for runtime use)
  use Agent

  @doc """
  Start the type mapper registry agent.
  """
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Register a custom type mapping.

  ## Parameters

    * `elixir_module` - Full Elixir module name (e.g., `"MyApp.User"`)
    * `rust_type` - Corresponding Rust type name
    * `fields` - List of field mappings

  ## Field mapping format

      %{
        name: "field_name",
        elixir_type: "String.t()",
        rust_type: "String"
      }

  ## Examples

      iex> Lux.Native.Types.TypeMapper.register_mapping("MyApp.User", "User", [
      ...>   %{name: "email", elixir_type: "String.t()", rust_type: "String"}
      ...> ])
      :ok
  """
  @spec register_mapping(String.t(), String.t(), [map()]) :: :ok
  def register_mapping(elixir_module, rust_type, fields) do
    Agent.update(__MODULE__, fn state ->
      Map.put(state, elixir_module, %{
        rust_type: rust_type,
        fields: fields,
        registered_at: DateTime.utc_now()
      })
    end)
  end

  @doc """
  Look up a custom type mapping by Elixir module name.
  """
  @spec get_mapping(String.t()) :: map() | nil
  def get_mapping(elixir_module) do
    Agent.get(__MODULE__, fn state ->
      Map.get(state, elixir_module)
    end)
  end

  @doc """
  List all registered custom type mappings.
  """
  @spec list_mappings() :: %{String.t() => map()}
  def list_mappings do
    Agent.get(__MODULE__, & &1)
  end

  @doc """
  Unregister a custom type mapping.
  """
  @spec unregister_mapping(String.t()) :: :ok
  def unregister_mapping(elixir_module) do
    Agent.update(__MODULE__, fn state ->
      Map.delete(state, elixir_module)
    end)
  end

  @doc """
  Validate that a value matches an expected type.
  """
  @spec validate_type?(term(), atom()) :: boolean()
  def validate_type?(value, :integer) when is_integer(value), do: true
  def validate_type?(value, :float) when is_float(value), do: true
  def validate_type?(value, :number) when is_number(value), do: true
  def validate_type?(value, :boolean) when is_boolean(value), do: true
  def validate_type?(value, :string) when is_binary(value), do: true
  def validate_type?(value, :atom) when is_atom(value), do: true
  def validate_type?(value, :list) when is_list(value), do: true
  def validate_type?(value, :map) when is_map(value), do: true
  def validate_type?(value, :tuple) when is_tuple(value), do: true
  def validate_type?(value, :nil) when is_nil(value), do: true
  def validate_type?(value, :struct) when is_struct(value), do: true
  def validate_type?(_, _), do: false

  @doc """
  Get the type signature for a value, including nested types.

  ## Examples

      iex> Lux.Native.Types.TypeMapper.type_signature([1, 2, 3])
      "list(integer)"

      iex> Lux.Native.Types.TypeMapper.type_signature(%{"a" => 1})
      "map(string, integer)"
  """
  @spec type_signature(term()) :: String.t()
  def type_signature(value) when is_list(value) do
    if value == [] do
      "list(empty)"
    else
      inner = value |> Enum.map(&type_signature/1) |> Enum.uniq() |> Enum.join(" | ")
      "list(#{inner})"
    end
  end

  def type_signature(value) when is_map(value) and not is_struct(value) do
    if map_size(value) == 0 do
      "map(empty)"
    else
      pairs =
        value
        |> Enum.take(3)
        |> Enum.map(fn {k, v} -> "#{type_signature(k)} => #{type_signature(v)}" end)
        |> Enum.join(", ")

      "map(#{pairs})"
    end
  end

  def type_signature(value) when is_tuple(value) do
    elements =
      value
      |> Tuple.to_list()
      |> Enum.map(&type_signature/1)
      |> Enum.join(", ")

    "tuple(#{elements})"
  end

  def type_signature(value) when is_struct(value) do
    module = value.__struct__
    "struct(#{inspect(module)})"
  end

  def type_signature(value) do
    detect_type(value) |> Atom.to_string()
  end

  @doc """
  Generate a Rust type definition string from an Elixir struct module.
  """
  @spec generate_rust_def(module()) :: String.t()
  def generate_rust_def(module) when is_atom(module) do
    fields = module.__struct__()
    # Get default values
    lines =
      fields
      |> Map.from_struct()
      |> Enum.map(fn {key, default} ->
        rust_type = infer_rust_type(default)
        "    pub #{key}: #{rust_type},"
      end)

    struct_name = module |> Module.split() |> List.last()

    "#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]\npub struct #{struct_name} {\n#{Enum.join(lines, "\n")}\n}"
  end

  defp infer_rust_type(value) do
    case detect_type(value) do
      :integer -> "i64"
      :float -> "f64"
      :boolean -> "bool"
      :string -> "String"
      :nil -> "Option<T>"
      :list -> "Vec<T>"
      :map -> "HashMap<String, T>"
      _ -> "serde_json::Value"
    end
  end
end
