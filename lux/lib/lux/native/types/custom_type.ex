defmodule Lux.Native.Types.CustomType do
  @moduledoc """
  Macros for defining custom types that have bidirectional mapping
  between Elixir structs and Rust types via NIF.

  ## Usage

      defmodule MyApp.User do
        use Lux.Native.Types.CustomType

        deftype do
          field :name, :string
          field :age, :integer, default: 0
          field :active, :boolean, default: true
          field :role, :atom, values: [:admin, :user, :guest]
        end
      end

  This generates:
  - A struct with the specified fields and defaults
  - A `__rust_type__/0` function returning the Rust type mapping
  - A `to_rust_map/1` function for serialization
  - A `from_rust_map/1` function for deserialization
  - Automatic registration in the Rust type registry

  ## Options

    * `:default` - Default value for the field
    * `:values` - Allowed values for atom/enum fields
  """

  defmacro __using__(_opts) do
    quote do
      import Lux.Native.Types.CustomType, only: [deftype: 1]
      @before_compile Lux.Native.Types.CustomType
      Module.register_attribute(__MODULE__, :custom_type_fields, accumulate: true)
    end
  end

  defmacro __before_compile__(_env) do
    # Nothing extra needed before compile
    nil
  end

  @doc """
  Define a custom type with typed fields.

  ## Field types

    * `:string` - String field
    * `:integer` - Integer field
    * `:float` - Float field
    * `:boolean` - Boolean field
    * `:atom` - Atom field (for enums)
    * `:list` - List field
    * `:map` - Map field

  ## Examples

      deftype do
        field :name, :string
        field :age, :integer, default: 0
        field :active, :boolean, default: true
      end
  """
  defmacro deftype(do: block) do
    quote do
      unquote(block)

      # Build struct from accumulated fields
      fields =
        @custom_type_fields
        |> Enum.reverse()
        |> Enum.map(fn {name, _type, opts} ->
          {name, Keyword.get(opts, :default)}
        end)

      defstruct fields

      @doc """
      Returns the Rust type mapping for this custom type.
      """
      def __rust_type__ do
        %{
          module: __MODULE__ |> Module.split() |> Enum.join("."),
          rust_name: __MODULE__ |> Module.split() |> List.last(),
          fields: @custom_type_fields |> Enum.reverse() |> Enum.map(fn {name, type, opts} ->
            %{
              name: name,
              type: type,
              rust_type: rust_type_for(type),
              has_default: Keyword.has_key?(opts, :default),
              default: Keyword.get(opts, :default),
              values: Keyword.get(opts, :values)
            }
          end)
        }
      end

      @doc """
      Convert this struct to a map suitable for Rust NIF serialization.
      """
      def to_rust_map(%__MODULE__{} = struct) do
        map = Map.from_struct(struct)

        map
        |> Enum.map(fn {key, value} ->
          {key, prepare_value(value)}
        end)
        |> Map.new()
      end

      @doc """
      Create a struct from a map returned by Rust NIF deserialization.
      """
      def from_rust_map(map) when is_map(map) do
        fields =
          @custom_type_fields
          |> Enum.reverse()
          |> Enum.map(fn {name, _type, _opts} ->
            {name, Map.get(map, Atom.to_string(name), Map.get(map, name))}
          end)

        struct(__MODULE__, fields)
      end

      @doc """
      Register this type with the Rust NIF type registry.
      """
      def register_type! do
        type_info = __rust_type__()

        field_defs =
          type_info.fields
          |> Enum.map(fn f ->
            base = %{name: Atom.to_string(f.name), type: f.rust_type}

            if f.has_default do
              Map.put(base, :default, f.default)
            else
              base
            end
          end)

        Lux.Native.Rust.register_type(%{
          module: "Elixir.#{type_info.module}",
          fields: field_defs
        })
      end

      defp rust_type_for(:string), do: "String"
      defp rust_type_for(:integer), do: "i64"
      defp rust_type_for(:float), do: "f64"
      defp rust_type_for(:boolean), do: "bool"
      defp rust_type_for(:atom), do: "Atom"
      defp rust_type_for(:list), do: "Vec<T>"
      defp rust_type_for(:map), do: "HashMap<String,T>"
      defp rust_type_for(other), do: inspect(other)

      defp prepare_value(value) when is_atom(value) and not is_nil(value) and not is_boolean(value) do
        Atom.to_string(value)
      end
      defp prepare_value(value) when is_list(value) do
        Enum.map(value, &prepare_value/1)
      end
      defp prepare_value(value) when is_map(value) do
        value
        |> Enum.map(fn {k, v} -> {prepare_value(k), prepare_value(v)} end)
        |> Map.new()
      end
      defp prepare_value(value), do: value
    end
  end

  @doc """
  Define a field within a custom type definition.
  """
  defmacro field(name, type, opts \\ []) do
    quote do
      @custom_type_fields {unquote(name), unquote(type), unquote(opts)}
    end
  end
end
