defmodule Lux.Native.Cargo.Dependency do
  @moduledoc """
  Cargo dependency management for the Lux Rust NIF project.

  Provides functions for parsing Cargo.toml, listing dependencies,
  checking version constraints, detecting outdated packages, and
  analyzing the dependency tree.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          source: String.t(),
          features: [String.t()],
          optional: boolean()
        }

  @enforce_keys [:name]
  defstruct [:name, :version, source: "registry", features: [], optional: false]

  @rust_dir Application.app_dir(:lux, "priv/rust")

  @doc """
  Lists all dependencies defined in the project's Cargo.toml.

  ## Options

    * `:rust_dir` - Override the Rust project directory

  ## Examples

      iex> Lux.Native.Cargo.Dependency.list()
      {:ok, [
        %Lux.Native.Cargo.Dependency{name: "rustler", version: "0.36", source: "registry", ...}
      ]}
  """
  @spec list(keyword()) :: {:ok, [t()]} | {:error, String.t()}
  def list(opts \\ []) do
    rust_dir = Keyword.get(opts, :rust_dir, @rust_dir)
    toml_path = Path.join(rust_dir, "Cargo.toml")

    with {:ok, contents} <- File.read(toml_path),
         {:ok, parsed} <- parse_toml_contents(contents) do
      deps =
        parsed
        |> Map.get("dependencies", %{})
        |> Enum.map(&dependency_from_entry/1)

      {:ok, deps}
    end
  end

  @doc """
  Parses the Cargo.toml file and returns structured data.

  ## Options

    * `:rust_dir` - Override the Rust project directory

  ## Examples

      iex> Lux.Native.Cargo.Dependency.parse_toml()
      {:ok, %{
        "package" => %{"name" => "lux_native", "version" => "0.1.0"},
        "dependencies" => %{"rustler" => "0.36"}
      }}
  """
  @spec parse_toml(keyword()) :: {:ok, map()} | {:error, String.t()}
  def parse_toml(opts \\ []) do
    rust_dir = Keyword.get(opts, :rust_dir, @rust_dir)
    toml_path = Path.join(rust_dir, "Cargo.toml")

    with {:ok, contents} <- File.read(toml_path) do
      parse_toml_contents(contents)
    end
  end

  @doc """
  Checks for outdated dependencies by comparing with the latest registry versions.

  Uses `cargo outdated` if available, otherwise falls back to `cargo update --dry-run`.

  ## Options

    * `:rust_dir` - Override the Rust project directory

  ## Examples

      iex> Lux.Native.Cargo.Dependency.outdated()
      {:ok, [%{name: "rustler", current: "0.35.0", latest: "0.36.0"}]}
  """
  @spec outdated(keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def outdated(opts \\ []) do
    rust_dir = Keyword.get(opts, :rust_dir, @rust_dir)

    case System.cmd("cargo", ["update", "--dry-run"], cd: rust_dir, stderr_to_stdout: true) do
      {output, 0} ->
        outdated = parse_outdated_output(output)
        {:ok, outdated}

      {output, _code} ->
        # cargo update --dry-run may return non-zero but still give useful output
        if String.contains?(output, "Updating") do
          outdated = parse_outdated_output(output)
          {:ok, outdated}
        else
          {:error, "Failed to check outdated dependencies: #{String.trim(output)}"}
        end
    end
  end

  @doc """
  Updates dependencies, optionally restricted to specific packages.

  ## Options

    * `:dry_run` - Only check, don't actually update (default: `false`)
    * `:packages` - List of specific packages to update
    * `:rust_dir` - Override the Rust project directory

  ## Examples

      iex> Lux.Native.Cargo.Dependency.update()
      {:ok, [%{name: "rustler", updated: true}]}

      iex> Lux.Native.Cargo.Dependency.update(packages: ["rustler"])
      {:ok, [%{name: "rustler", updated: true}]}
  """
  @spec update(keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def update(opts \\ []) do
    rust_dir = Keyword.get(opts, :rust_dir, @rust_dir)
    packages = Keyword.get(opts, :packages, [])
    dry_run = Keyword.get(opts, :dry_run, false)

    args = if dry_run, do: ["update", "--dry-run"], else: ["update"]

    args =
      args ++
        Enum.flat_map(packages, fn pkg ->
          ["-p", pkg]
        end)

    case System.cmd("cargo", args, cd: rust_dir, stderr_to_stdout: true) do
      {output, 0} ->
        results =
          output
          |> String.split("\n")
          |> Enum.filter(&String.contains?(&1, "Updating"))
          |> Enum.map(fn line ->
            case Regex.run(~r/Updating\s+(\S+)\s+v(\S+)\s+->\s+v(\S+)/, line) do
              [_, name, _old, _new] -> %{name: name, updated: true}
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        if results == [] do
          {:ok, [%{name: "all", updated: true}]}
        else
          {:ok, results}
        end

      {output, code} ->
        {:error, "cargo update failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  @doc """
  Returns the dependency tree as a nested structure.

  Uses `cargo tree` to analyze the full dependency graph.

  ## Options

    * `:rust_dir` - Override the Rust project directory
    * `:prefix` - Filter tree to show only dependencies under this prefix

  ## Examples

      iex> Lux.Native.Cargo.Dependency.tree()
      {:ok, %{
        name: "lux_native",
        version: "0.1.0",
        dependencies: [
          %{name: "rustler", version: "0.36.0", dependencies: []}
        ]
      }}
  """
  @spec tree(keyword()) :: {:ok, map()} | {:error, String.t()}
  def tree(opts \\ []) do
    rust_dir = Keyword.get(opts, :rust_dir, @rust_dir)

    case System.cmd("cargo", ["tree", "--format", "{p}"],
           cd: rust_dir,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, parse_tree_output(output)}

      {output, code} ->
        {:error, "cargo tree failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  @doc """
  Checks if a specific dependency is present and returns its version constraint.

  ## Examples

      iex> Lux.Native.Cargo.Dependency.check("rustler")
      {:ok, %{name: "rustler", version: "0.36", present: true}}

      iex> Lux.Native.Cargo.Dependency.check("nonexistent")
      {:ok, %{name: "nonexistent", version: nil, present: false}}
  """
  @spec check(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def check(package_name, opts \\ []) do
    case list(opts) do
      {:ok, deps} ->
        case Enum.find(deps, &(&1.name == package_name)) do
          nil -> {:ok, %{name: package_name, version: nil, present: false}}
          dep -> {:ok, %{name: dep.name, version: dep.version, present: true}}
        end

      error ->
        error
    end
  end

  # --- Private Helpers ---

  defp dependency_from_entry({name, version}) when is_binary(version) do
    %__MODULE__{
      name: name,
      version: version,
      source: "registry",
      features: [],
      optional: false
    }
  end

  defp dependency_from_entry({name, config}) when is_map(config) do
    %__MODULE__{
      name: name,
      version: Map.get(config, "version", "*"),
      source: determine_source(config),
      features: Map.get(config, "features", []),
      optional: Map.get(config, "optional", false)
    }
  end

  defp determine_source(config) do
    cond do
      Map.has_key?(config, "git") -> "git"
      Map.has_key?(config, "path") -> "path"
      true -> "registry"
    end
  end

  defp parse_toml_contents(contents) do
    # Simple TOML parser for Cargo.toml files.
    # Handles [sections] and key = value pairs, including inline tables.
    result =
      contents
      |> String.split("\n")
      |> Enum.reduce({%{}, nil, nil}, fn line, {acc, current_section, _} ->
        line = String.trim(line)

        cond do
          # Skip empty lines and comments
          line == "" or String.starts_with?(line, "#") ->
            {acc, current_section, nil}

          # Section header [section]
          Regex.match?(~r/^\[[^\]]+\]$/, line) ->
            section = line |> String.trim("[" ) |> String.trim("]") |> String.trim()
            {Map.put_new(acc, section, %{}), section, nil}

          # Key = value
          current_section != nil and String.contains?(line, "=") ->
            [key | rest] = String.split(line, "=", parts: 2)
            key = String.trim(key)
            value = parse_toml_value(Enum.join(rest, "=") |> String.trim())
            section_data = Map.get(acc, current_section, %{})
            {Map.put(acc, current_section, Map.put(section_data, key, value)), current_section, nil}

          true ->
            {acc, current_section, nil}
        end
      end)
      |> elem(0)

    {:ok, result}
  rescue
    e -> {:error, "Failed to parse Cargo.toml: #{inspect(e)}"}
  end

  defp parse_toml_value(value) do
    cond do
      # String
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        String.trim(value, "\"")

      # Inline table (simplified)
      String.starts_with?(value, "{") ->
        parse_inline_table(value)

      # Array
      String.starts_with?(value, "[") ->
        value
        |> String.trim("[")
        |> String.trim("]")
        |> String.split(",")
        |> Enum.map(&parse_toml_value/1)

      # Boolean
      value == "true" -> true
      value == "false" -> false

      # Number
      Regex.match?(~r/^\d+$/, value) ->
        String.to_integer(value)

      Regex.match?(~r/^\d+\.\d+$/, value) ->
        String.to_float(value)

      # Default: string
      true ->
        value
    end
  end

  defp parse_inline_table(value) do
    value
    |> String.trim("{")
    |> String.trim("}")
    |> String.split(",")
    |> Enum.map(fn pair ->
      [k, v] = String.split(pair, "=", parts: 2)
      {String.trim(k), parse_toml_value(String.trim(v))}
    end)
    |> Map.new()
  end

  defp parse_outdated_output(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "Updating"))
    |> Enum.map(fn line ->
      case Regex.run(~r/Updating\s+(\S+)\s+v(\S+)\s+->\s+v(\S+)/, line) do
        [_, name, current, latest] ->
          %{name: name, current: current, latest: latest}

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_tree_output(output) do
    lines =
      output
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(&1 != ""))

    case lines do
      [] ->
        %{name: "unknown", version: "0.0.0", dependencies: []}

      [root | rest] ->
        {name, version} = parse_package_line(root)
        deps = rest |> Enum.map(&parse_package_line/1) |> Enum.map(fn {n, v} -> %{name: n, version: v, dependencies: []} end)

        %{name: name, version: version, dependencies: deps}
    end
  end

  defp parse_package_line(line) do
    # Format: name version (source)
    line = String.replace(line, ~r/[│├└─\s]+/, " ") |> String.trim()

    case Regex.run(~r/(\S+)\s+v(\S+)/, line) do
      [_, name, version] -> {name, version}
      _ -> {"unknown", "0.0.0"}
    end
  end
end
