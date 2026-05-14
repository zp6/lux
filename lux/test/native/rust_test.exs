defmodule Lux.Native.RustTest do
  use ExUnit.Case, async: true

  alias Lux.Native.Rust

  describe "add/2" do
    test "adds two integers" do
      assert {:ok, result} = Rust.add(1, 2)
      assert result == 3.0
    end

    test "adds two floats" do
      assert {:ok, result} = Rust.add(1.5, 2.5)
      assert result == 4.0
    end

    test "adds integer and float" do
      assert {:ok, result} = Rust.add(1, 2.5)
      assert result == 3.5
    end

    test "handles negative numbers" do
      assert {:ok, result} = Rust.add(-1, -2)
      assert result == -3.0
    end

    test "handles zero" do
      assert {:ok, result} = Rust.add(0, 0)
      assert result == 0.0
    end
  end

  describe "echo/1" do
    test "returns integer unchanged" do
      assert Rust.echo(42) == 42
    end

    test "returns string unchanged" do
      assert Rust.echo("hello") == "hello"
    end

    test "returns atom unchanged" do
      assert Rust.echo(:hello) == :hello
    end

    test "returns list unchanged" do
      assert Rust.echo([1, 2, 3]) == [1, 2, 3]
    end

    test "returns map unchanged" do
      assert Rust.echo(%{a: 1}) == %{a: 1}
    end
  end

  describe "uuid_v4/0" do
    test "generates a valid UUID v4 string" do
      assert {:ok, uuid} = Rust.uuid_v4()
      assert is_binary(uuid)
      assert String.length(uuid) == 36

      # UUID v4 format: 8-4-4-4-12 hex digits
      assert String.match?(
               uuid,
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
             )
    end

    test "generates unique UUIDs" do
      {:ok, uuid1} = Rust.uuid_v4()
      {:ok, uuid2} = Rust.uuid_v4()
      # Extremely unlikely to be equal
      refute uuid1 == uuid2
    end
  end

  describe "sha256/1" do
    test "computes correct SHA-256 hash" do
      # Known SHA-256("hello")
      expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
      assert {:ok, hash} = Rust.sha256("hello")
      assert hash == expected
    end

    test "computes hash of empty string" do
      # Known SHA-256("")
      expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      assert {:ok, hash} = Rust.sha256("")
      assert hash == expected
    end

    test "returns a 64-character hex string" do
      assert {:ok, hash} = Rust.sha256("test data")
      assert String.length(hash) == 64
      assert String.match?(hash, ~r/^[0-9a-f]{64}$/)
    end
  end

  describe "serialize_json/1" do
    test "serializes a simple map" do
      assert {:ok, json} = Rust.serialize_json(%{"name" => "Lux"})
      assert json =~ "\"name\""
      assert json =~ "\"Lux\""
    end

    test "serializes a list" do
      assert {:ok, json} = Rust.serialize_json([1, 2, 3])
      assert json =~ "["
      assert json =~ "]"
    end
  end

  describe "type round-trip" do
    test "integer round-trip via echo" do
      assert Rust.echo(123) == 123
    end

    test "float round-trip via echo" do
      assert Rust.echo(3.14) == 3.14
    end

    test "boolean round-trip via echo" do
      assert Rust.echo(true) == true
      assert Rust.echo(false) == false
    end

    test "nil round-trip via echo" do
      assert Rust.echo(nil) == nil
    end
  end

  describe "error handling" do
    test "add always returns ok tuple for valid inputs" do
      assert {:ok, _} = Rust.add(0, 0)
      assert {:ok, _} = Rust.add(999_999, 1)
    end
  end
end
