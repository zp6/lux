defmodule Lux.Native.Cargo.Build do
  @moduledoc """
  Build system integration for Cargo-based Rust NIFs in Lux.

  Provides functions for compiling Rust code, managing build configurations,
  handling build caching, and supporting cross-compilation targets.
  """

  @rust_dir Application.app_dir(:lux, "priv/rust")

  @type build_profile :: :debug | :release
  @type build_config :: %{
          profile: build_profile(),
          target: String.t() | nil,
          features: [String.t()],
          rust_dir: String.t()
        }

  @doc """
  Compiles the Rust NIF project.

  ## Options

    * `:profile` - Build profile, `:debug` or `:release` (default: `:release`)
    * `:target` - Cross-compilation target triple
    * `:features` - List of Cargo features to enable
    * `:rust_dir` - Override the Rust project directory
    * `:timeout` - Build timeout in milliseconds (default: 300_000)
    * `:env` - Additional environment variables

  ## Examples

      iex> Lux.Native.Cargo.Build.compile()
      {:ok, %{profile: :release, artifacts: ["liblux_native.so"]}}

      iex> Lux.Native.Cargo.Build.compile(profile: :debug, features: ["serde"])
      {:ok, %{profile: :debug, artifacts: [...], features: ["serde"]}}
  """
  @spec compile(keyword()) :: {:ok, map()} | {:error, String.t()}
  def compile(opts \\ []) do
    rust_dir = Keyword.get(opts, :rust_dir, @rust_dir)
    profile = Keyword.get(opts, :profile, :release)
    target = Keyword.get(opts, :target)
    features = Keyword.get(opts, :features, [])
    timeout = Keyword.get(opts, :timeout, 300_000)
    env = Keyword.get(opts, :env, [])

    unless File.dir?(rust_dir) do
      {:error, "Rust project directory not found: #{rust_dir}"}
    end

    args = build_args(profile, target, features)

    full_env =
      env ++
        System.get_env()
        |> Enum.to_list()

    case System.cmd("cargo", args,
           cd: rust_dir,
           env: full_env,
           stderr_to_stdout: true,
           timeout: timeout
         ) do
      {_output, 0} ->
        artifact_info = %{
          profile: profile,
          artifacts: find_artifacts(rust_dir, profile, target),
          rust_dir: rust_dir
        }

        artifact_info =
          if target,
            do: Map.put(artifact_info, :target, target),
            else: artifact_info

        artifact_info =
          if features != [],
            do: Map.put(artifact_info, :features, features),
            else: artifact_info

        {:ok, artifact_info}

      {output, code} ->
        {:error, "Cargo build failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  @doc """
  Returns the build status of the Rust NIF project.

  Checks if the compiled artifact exists and reports its modification time.

  ## Options

    * `:rust_dir` - Override the Rust project directory
    * `:profile` - Check specific profile (default: `:release`)

  ## Examples

      iex> Lux.Native.Cargo.Build.status()
      {:ok, %{compiled: true, profile: :release, modified_at: ~U[2024-01-01 00:00:00Z]}}
  """
  @spec status(keyword()) :: {:ok, map()} | {:error, String.t()}
  def status(opts \\ []) do
    rust_dir = Keyword.get(opts, :rust_dir, @rust_dir)
    profile = Keyword.get(opts, :profile, :release)

    artifacts = find_artifacts(rust_dir, profile, nil)

    if artifacts == [] do
      {:ok, %{compiled: false, profile: profile, artifacts: []}}
    else
      # Get the modification time of the first artifact
      artifact_path = Path.join([rust_dir, artifact_dir(profile, nil), artifact_filename()])

      modified_at =
        case File.stat(artifact_path) do
          {:ok, %File.Stat{mtime: mtime}} -> mtime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")
          _ -> nil
        end

      {:ok,
       %{
         compiled: true,
         profile: profile,
         artifacts: artifacts,
         modified_at: modified_at
       }}
    end
  end

  @doc """
  Cleans build artifacts.

  ## Options

    * `:rust_dir` - Override the Rust project directory
    * `:release` - Only clean release artifacts (default: `false`)

  ## Examples

      iex> Lux.Native.Cargo.Build.clean()
      {:ok, :cleaned}
  """
  @spec clean(keyword()) :: {:ok, :cleaned} | {:error, String.t()}
  def clean(opts \\ []) do
    rust_dir = Keyword.get(opts, :rust_dir, @rust_dir)

    case System.cmd("cargo", ["clean"], cd: rust_dir, stderr_to_stdout: true) do
      {_output, 0} -> {:ok, :cleaned}
      {output, code} -> {:error, "cargo clean failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  @doc """
  Returns the default build configuration.

  ## Examples

      iex> Lux.Native.Cargo.Build.default_config()
      %{profile: :release, target: nil, features: [], rust_dir: "/path/to/priv/rust"}
  """
  @spec default_config() :: build_config()
  def default_config do
    %{
      profile: :release,
      target: nil,
      features: [],
      rust_dir: @rust_dir
    }
  end

  @doc """
  Checks if the source files have changed since the last build.

  Returns `{:ok, true}` if rebuild is needed, `{:ok, false}` if artifacts are up to date.

  ## Options

    * `:rust_dir` - Override the Rust project directory
    * `:profile` - Check specific profile (default: `:release`)

  ## Examples

      iex> Lux.Native.Cargo.Build.needs_rebuild?()
      {:ok, true}
  """
  @spec needs_rebuild?(keyword()) :: {:ok, boolean()} | {:error, String.t()}
  def needs_rebuild?(opts \\ []) do
    rust_dir = Keyword.get(opts, :rust_dir, @rust_dir)
    profile = Keyword.get(opts, :profile, :release)

    # Find the latest source file modification time
    src_dir = Path.join(rust_dir, "src")

    with {:ok, src_mtime} <- latest_mtime(src_dir) do
      artifact_path = Path.join([rust_dir, artifact_dir(profile, nil), artifact_filename()])

      case File.stat(artifact_path) do
        {:ok, %File.Stat{mtime: artifact_mtime}} ->
          {:ok, src_mtime > artifact_mtime}

        {:error, :enoent} ->
          {:ok, true}

        error ->
          {:error, "Failed to stat artifact: #{inspect(error)}"}
      end
    end
  end

  # --- Private Helpers ---

  defp build_args(profile, target, features) do
    base = ["build"]

    base =
      case profile do
        :release -> base ++ ["--release"]
        :debug -> base
      end

    base =
      if target do
        base ++ ["--target", target]
      else
        base
      end

    if features != [] do
      base ++ ["--features", Enum.join(features, ",")]
    else
      base
    end
  end

  defp find_artifacts(rust_dir, profile, target) do
    dir = Path.join([rust_dir, artifact_dir(profile, target)])

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&artifact_match?/1)
    else
      []
    end
  end

  defp artifact_dir(:release, nil), do: "target/release"
  defp artifact_dir(:debug, nil), do: "target/debug"
  defp artifact_dir(:release, target), do: "target/#{target}/release"
  defp artifact_dir(:debug, target), do: "target/#{target}/debug"

  defp artifact_filename do
    case :os.type() do
      {:win32, _} -> "lux_native.dll"
      {:unix, :darwin} -> "liblux_native.dylib"
      {:unix, _} -> "liblux_native.so"
    end
  end

  defp artifact_match?(filename) do
    String.ends_with?(filename, ".so") or
      String.ends_with?(filename, ".dylib") or
      String.ends_with?(filename, ".dll")
  end

  defp latest_mtime(dir) do
    if File.dir?(dir) do
      mtime =
        dir
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(fn f ->
          {:ok, %File.Stat{mtime: mtime}} = File.stat(f)
          mtime
        end)
        |> Enum.max(fn -> {{0, 0, 0}, {0, 0, 0}} end)

      {:ok, mtime}
    else
      {:error, "Source directory not found: #{dir}"}
    end
  end
end
