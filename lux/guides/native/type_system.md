# Rust Type System and Serialization

Advanced type mapping and serialization between Elixir and Rust.

## Overview

The type system provides seamless bidirectional conversion between Elixir and Rust data types, enabling complex data exchange through NIF boundaries.

## Quick Start

```elixir
alias Lux.Native.Types.{Serializer, TypeMapper, CustomType}

# Type mapping
TypeMapper.to_rust(:integer)    # => "i64"
TypeMapper.to_rust({:list, :string})  # => "Vec<String>"
TypeMapper.to_elixir("f64")    # => :float

# Serialization
{:ok, json} = Serializer.serialize(%{"name" => "Alice", "age" => 30})
{:ok, map} = Serializer.deserialize(json)

# Custom types
defmodule User do
  use CustomType
  field :name, :string
  field :age, :integer
  field :email, :string
end

rust_struct = CustomType.to_rust_struct(User)
# => %{name: "User", fields: [name: "String", age: "i64", email: "String"]}
```

## Type Mapping Reference

| Elixir | Rust | Notes |
|--------|------|-------|
| `:integer` | `i64` | Default integer type |
| `:float` | `f64` | Double precision |
| `:string` | `String` | UTF-8 owned string |
| `:boolean` | `bool` | true/false |
| `:atom` | `Atom` | Custom enum mapping |
| `{:list, t}` | `Vec<T>` | Homogeneous list |
| `{:map, k, v}` | `HashMap<K, V>` | Key-value map |
| `{:tuple, types}` | `(T1, T2, ...)` | Fixed-size tuple |
| Custom struct | `struct` | Via CustomType macro |

## Serde Integration

Rust types implement `Serialize` and `Deserialize` from Serde:

```rust
use serde::{Serialize, Deserialize};

#[derive(Serialize, Deserialize)]
struct User {
    name: String,
    age: i64,
    email: String,
}
```

Bidirectional conversion handles:
- Elixir atoms ↔ Rust enums
- Elixir structs ↔ Rust structs
- Nested containers (Vec<Vec<T>>, HashMap<String, Vec<T>>)
- Option types (`nil` ↔ `None`)

## Configuration

```elixir
config :lux, Lux.Native.Types,
  custom_type_module: Lux.Native.Types.CustomType,
  default_int_type: :i64,
  default_float_type: :f64,
  strict_mode: true  # raise on unknown types
```
