defmodule Lux.Native.TypesTest do
  use UnitCase, async: true

  alias Lux.Native.Types.{Serializer, TypeMapper, CustomType}

  describe "TypeMapper" do
    test "maps primitive Elixir types to Rust type identifiers" do
      assert TypeMapper.to_rust(:integer) == "i64"
      assert TypeMapper.to_rust(:float) == "f64"
      assert TypeMapper.to_rust(:string) == "String"
      assert TypeMapper.to_rust(:boolean) == "bool"
      assert TypeMapper.to_rust(:atom) == "Atom"
    end

    test "maps container types" do
      assert TypeMapper.to_rust({:list, :integer}) == "Vec<i64>"
      assert TypeMapper.to_rust({:map, :string, :integer}) == "HashMap<String, i64>"
      assert TypeMapper.to_rust({:tuple, [:string, :integer]}) == "(String, i64)"
    end

    test "maps Rust types back to Elixir" do
      assert TypeMapper.to_elixir("i64") == :integer
      assert TypeMapper.to_elixir("f64") == :float
      assert TypeMapper.to_elixir("String") == :string
      assert TypeMapper.to_elixir("bool") == :boolean
    end

    test "handles unknown types" do
      assert TypeMapper.to_rust(:unknown) == {:error, "Unknown type: unknown"}
    end
  end

  describe "Serializer" do
    test "serializes primitive types to JSON" do
      assert Serializer.serialize(42) == {:ok, "42"}
      assert Serializer.serialize(3.14) == {:ok, "3.14"}
      assert Serializer.serialize("hello") == {:ok, "\"hello\""}
      assert Serializer.serialize(true) == {:ok, "true"}
    end

    test "serializes atoms as strings" do
      assert Serializer.serialize(:ok) == {:ok, "\"ok\""}
      assert Serializer.serialize(:error) == {:ok, "\"error\""}
    end

    test "serializes lists" do
      assert Serializer.serialize([1, 2, 3]) == {:ok, "[1,2,3]"}
    end

    test "serializes maps" do
      assert {:ok, json} = Serializer.serialize(%{"a" => 1})
      assert json =~ ~s("a")
      assert json =~ "1"
    end

    test "deserializes JSON to Elixir terms" do
      assert Serializer.deserialize("42") == {:ok, 42}
      assert Serializer.deserialize("\"hello\"") == {:ok, "hello"}
      assert Serializer.deserialize("true") == {:ok, true}
      assert Serializer.deserialize("[1,2,3]") == {:ok, [1, 2, 3]}
    end

    test "bidirectional serialization round-trips" do
      values = [42, 3.14, "hello", true, [1, 2, 3]]
      for v <- values do
        {:ok, json} = Serializer.serialize(v)
        {:ok, decoded} = Serializer.deserialize(json)
        assert decoded == v, "Round-trip failed for #{inspect(v)}"
      end
    end
  end

  describe "CustomType" do
    test "defines custom struct types" do
      defmodule TestUser do
        use CustomType

        field :name, :string
        field :age, :integer
        field :email, :string
      end

      assert TestUser.__fields__() == [name: :string, age: :integer, email: :string]
    end

    test "converts custom type to Rust struct definition" do
      defmodule TestPoint do
        use CustomType

        field :x, :float
        field :y, :float
      end

      rust_def = CustomType.to_rust_struct(TestPoint)
      assert rust_def.name == "TestPoint"
      assert rust_def.fields == [x: "f64", y: "f64"]
    end

    test "serializes custom types" do
      defmodule TestProduct do
        use CustomType

        field :id, :integer
        field :name, :string
        field :price, :float
      end

      product = %TestProduct{id: 1, name: "Widget", price: 9.99}
      {:ok, json} = Serializer.serialize(product)
      assert json =~ "Widget"
      assert json =~ "9.99"
    end
  end
end
