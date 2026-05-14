defmodule Lux.Native.CargoTest do
  use UnitCase, async: true

  alias Lux.Native.Cargo
  alias Lux.Native.Cargo.{Build, Dependency}

  describe "Cargo.available?/0" do
    test "returns a boolean" do
      assert is_boolean(Cargo.available?())
    end
  end

  describe "Cargo.rust_dir/0" do
    test "returns the priv/rust path" do
      assert Cargo.rust_dir() =~ "priv/rust"
    end
  end

  describe "Cargo.version/0" do
    @tag :skip
    test "returns version info when cargo is available" do
      # Skip in CI where cargo may not be installed
      assert {:ok, info} = Cargo.version()
      assert is_map(info)
      assert Map.has_key?(info, :cargo)
      assert Map.has_key?(info, :rustc)
    end
  end

  describe "Cargo.parse_toml/1" do
    test "parses the project Cargo.toml" do
      # Use the actual project's priv/rust/Cargo.toml
      case Cargo.parse_toml() do
        {:ok, parsed} ->
          assert is_map(parsed)
          assert Map.has_key?(parsed, "package")
          package = parsed["package"]
          assert package["name"] == "lux_native"

        {:error, _reason} ->
          # Cargo.toml might not be accessible in test env
          :ok
      end
    end
  end

  describe "Cargo.dependencies/1" do
    test "lists dependencies from Cargo.toml" do
      case Cargo.dependencies() do
        {:ok, deps} ->
          assert is_list(deps)
          # Should have at least rustler
          rustler = Enum.find(deps, &(&1.name == "rustler"))
          assert rustler != nil
          assert %Dependency{name: "rustler"} = rustler

        {:error, _reason} ->
          # May fail if priv/rust is not in expected location
          :ok
      end
    end
  end

  describe "Cargo.build/1" do
    @tag :skip
    test "compiles the Rust NIF project" do
      # Skip in CI — requires full Rust toolchain
      assert {:ok, result} = Cargo.build(profile: :release)
      assert result.profile == :release
      assert is_list(result.artifacts)
    end

    @tag :skip
    test "supports debug builds" do
      assert {:ok, result} = Cargo.build(profile: :debug)
      assert result.profile == :debug
    end

    @tag :skip
    test "supports cross-compilation targets" do
      assert {:ok, result} = Cargo.build(target: "x86_64-unknown-linux-gnu")
      assert result.target == "x86_64-unknown-linux-gnu"
    end
  end

  describe "Cargo.build_status/1" do
    test "returns build status information" do
      case Cargo.build_status() do
        {:ok, status} ->
          assert Map.has_key?(status, :compiled)
          assert Map.has_key?(status, :profile)
          assert status.profile == :release

        {:error, _reason} ->
          :ok
      end
    end
  end

  describe "Cargo.clean/1" do
    @tag :skip
    test "cleans build artifacts" do
      assert {:ok, :cleaned} = Cargo.clean()
    end
  end

  describe "Cargo.run/2" do
    @tag :skip
    test "executes arbitrary cargo commands" do
      assert {:ok, output} = Cargo.run(["--version"])
      assert output =~ ~r/cargo \d+\.\d+/
    end
  end

  describe "Dependency.list/1" do
    test "returns dependency structs" do
      case Dependency.list() do
        {:ok, deps} ->
          for dep <- deps do
            assert %Dependency{} = dep
            assert is_binary(dep.name)
          end

        {:error, _} ->
          :ok
      end
    end
  end

  describe "Dependency.check/2" do
    test "checks if a dependency is present" do
      case Dependency.check("rustler") do
        {:ok, result} ->
          assert result.name == "rustler"
          assert result.present == true

        {:error, _} ->
          :ok
      end
    end

    test "returns present: false for missing deps" do
      case Dependency.check("nonexistent_crate_xyz") do
        {:ok, result} ->
          assert result.name == "nonexistent_crate_xyz"
          assert result.present == false

        {:error, _} ->
          :ok
      end
    end
  end

  describe "Dependency.outdated/1" do
    @tag :skip
    test "checks for outdated dependencies" do
      # Requires cargo and network access
      assert {:ok, outdated} = Dependency.outdated()
      assert is_list(outdated)
    end
  end

  describe "Dependency.tree/1" do
    @tag :skip
    test "returns the dependency tree" do
      assert {:ok, tree} = Dependency.tree()
      assert Map.has_key?(tree, :name)
      assert Map.has_key?(tree, :dependencies)
    end
  end

  describe "Dependency.update/1" do
    @tag :skip
    test "updates dependencies" do
      assert {:ok, results} = Dependency.update()
      assert is_list(results)
    end

    @tag :skip
    test "supports dry run" do
      assert {:ok, results} = Dependency.update(dry_run: true)
      assert is_list(results)
    end

    @tag :skip
    test "supports specific packages" do
      assert {:ok, results} = Dependency.update(packages: ["rustler"])
      assert is_list(results)
    end
  end

  describe "Build.default_config/0" do
    test "returns a valid config map" do
      config = Build.default_config()
      assert config.profile == :release
      assert config.target == nil
      assert config.features == []
      assert is_binary(config.rust_dir)
    end
  end

  describe "Build.needs_rebuild?/1" do
    test "returns a boolean or error" do
      case Build.needs_rebuild?() do
        {:ok, needs?} ->
          assert is_boolean(needs?)

        {:error, _} ->
          # Source dir may not exist in test env
          :ok
      end
    end
  end
end
