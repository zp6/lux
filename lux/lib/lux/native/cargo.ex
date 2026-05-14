defmodule Lux.Native.Cargo do
  @moduledoc """
  Provides Cargo package management integration for Rust NIFs in Lux.

  Cargo is the Rust package manager and build system. This module provides
  Elixir bindings for common Cargo operations including dependency management,
  build execution, version checking, and release management.

  ## Quick Start

      # Check if cargo is available
      {:ok, version} = Lux.Native.Cargo.version()

      # Build the project
      {:ok, artifacts} = Lux.Native.Cargo.build()

      # Check dependencies
      {:ok, deps} = Lux.Native.Cargo.dependencies()

  ## Configuration

  Add to your application config:

      config :lux, :cargo,
        rust_dir: "priv/rust",
        profile: :release,
        target: nil

  ## Integration with Rust NIFs

  This module works alongside the existing `priv/rust` NIF setup,
  providing higher-level management operations while the NIF module
  handles the actual native function calls.
  """

  alias Lux.Native.Cargo.{Build, Dependency}

  @type cargo_option ::
          {:rust_dir, String.t()}
          | {:profile, :debug | :release}
          | {:target, String.t() | nil}
          | {:timeout, pos_integer()}

  @type cargo_options :: [cargo_option()]

  @type version_info :: %{
          cargo: String.t(),
          rustc: String.t(),
          rustfmt: String.t() | nil
        }

  @rust_dir Application.app_dir(:lux, "priv/rust")

  @doc """
  Returns the path to the Rust project directory used by Lux.
  """
  @spec rust_dir() :: String.t()
  def rust_dir, do: @rust_dir

  @doc """
  Returns Cargo and Rust toolchain version information.

  ## Examples

      iex> Lux.Native.Cargo.version()
      {:ok, %{cargo: "1.77.0", rustc: "1.77.0", rustfmt: "1.7.0"}}
  """
  @spec version() :: {:ok, version_info()} | {:error, String.t()}
  def version do
    with {:ok, cargo} <- run_cmd(["--version"]),
         {:ok, rustc} <- run_cmd(["rustc", "--version"]),
         rustfmt <- run_cmd_safe(["rustfmt", "--version"]) do
      {:ok,
       %{
         cargo: parse_version(cargo),
         rustc: parse_version(rustc),
         rustfmt: parse_version(rustfmt)
       }}
    end
  end

  @doc """
  Checks if Cargo is available on the system.
  """
  @spec available?() :: boolean()
  def available? do
    case System.find_executable("cargo") do
      nil -> false
      _path -> true
    end
  end

  @doc """
  Builds the Rust NIF project using Cargo.

  ## Options

    * `:profile` - Build profile, either `:debug` or `:release` (default: `:release`)
    * `:target` - Cross-compilation target triple (e.g., `"x86_64-pc-windows-msvc"`)
    * `:timeout` - Build timeout in milliseconds (default: 300_000)
    * `:rust_dir` - Override the Rust project directory

  ## Examples

      iex> Lux.Native.Cargo.build()
      {:ok, %{profile: :release, artifacts: [...]}}

      iex> Lux.Native.Cargo.build(profile: :debug)
      {:ok, %{profile: :debug, artifacts: [...]}}

      iex> Lux.Native.Cargo.build(target: "x86_64-unknown-linux-gnu")
      {:ok, %{profile: :release, target: "x86_64-unknown-linux-gnu", artifacts: [...]}}
  """
  @spec build(cargo_options()) :: {:ok, map()} | {:error, String.t()}
  def build(opts \\ []) do
    Build.compile(opts)
  end

  @doc """
  Lists all dependencies defined in the project's Cargo.toml.

  ## Examples

      iex> Lux.Native.Cargo.dependencies()
      {:ok, [%{name: "rustler", version: "0.36", source: "registry"}]}
  """
  @spec dependencies(keyword()) :: {:ok, [Dependency.t()]} | {:error, String.t()}
  def dependencies(opts \\ []) do
    Dependency.list(opts)
  end

  @doc """
  Checks for outdated dependencies.

  ## Options

    * `:rust_dir` - Override the Rust project directory

  ## Examples

      iex> Lux.Native.Cargo.outdated()
      {:ok, [%{name: "rustler", current: "0.35.0", latest: "0.36.0"}]}
  """
  @spec outdated(keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def outdated(opts \\ []) do
    Dependency.outdated(opts)
  end

  @doc """
  Updates dependencies in the Cargo.toml.

  ## Options

    * `:dry_run` - Only check, don't actually update (default: `false`)
    * `:packages` - List of specific packages to update

  ## Examples

      iex> Lux.Native.Cargo.update_deps()
      {:ok, [%{name: "rustler", updated: true}]}

      iex> Lux.Native.Cargo.update_deps(packages: ["rustler"])
      {:ok, [%{name: "rustler", updated: true}]}
  """
  @spec update_deps(keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def update_deps(opts \\ []) do
    Dependency.update(opts)
  end

  @doc """
  Parses the project's Cargo.toml and returns structured data.

  ## Examples

      iex> Lux.Native.Cargo.parse_toml()
      {:ok, %{name: "lux_native", version: "0.1.0", dependencies: %{"rustler" => "0.36"}}}
  """
  @spec parse_toml(keyword()) :: {:ok, map()} | {:error, String.t()}
  def parse_toml(opts \\ []) do
    Dependency.parse_toml(opts)
  end

  @doc """
  Returns the build status and cached artifacts.

  ## Examples

      iex> Lux.Native.Cargo.build_status()
      {:ok, %{compiled: true, profile: :release, modified_at: ~U[2024-01-01 00:00:00Z]}}
  """
  @spec build_status(keyword()) :: {:ok, map()} | {:error, String.t()}
  def build_status(opts \\ []) do
    Build.status(opts)
  end

  @doc """
  Cleans build artifacts.

  ## Options

    * `:release` - Only clean release artifacts (default: `false`)
    * `:rust_dir` - Override the Rust project directory

  ## Examples

      iex> Lux.Native.Cargo.clean()
      {:ok, :cleaned}
  """
  @spec clean(keyword()) :: {:ok, :cleaned} | {:error, String.t()}
  def clean(opts \\ []) do
    Build.clean(opts)
  end

  @doc """
  Runs a Cargo command and returns the output.

  ## Options

    * `:timeout` - Command timeout in milliseconds (default: 60_000)
    * `:env` - Environment variables to set

  ## Examples

      iex> Lux.Native.Cargo.run(["check"])
      {:ok, "Checking lux_native v0.1.0"}
  """
  @spec run([String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    env = Keyword.get(opts, :env, [])
    cwd = Keyword.get(opts, :cwd) || rust_dir()

    cmd = ["cargo" | args]

    case System.cmd("cargo", Enum.drop(cmd, 1),
           cd: cwd,
           env: env,
           stderr_to_stdout: true,
           timeout: timeout
         ) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, code} ->
        {:error, "Cargo command failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  # --- Private Helpers ---

  defp run_cmd(args) do
    case System.cmd("cargo", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  end

  defp run_cmd_safe(args) do
    case System.cmd("cargo", args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp parse_version(nil), do: nil

  defp parse_version(output) do
    case Regex.run(~r/(\d+\.\d+[\.\d]*)/, output) do
      [_, version] -> version
      _ -> output
    end
  end
end
