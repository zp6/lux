defmodule Lux.NodeJS do
  @moduledoc """
  Provides functions for executing Node.js code with variable bindings.

  The ~JS sigil is used to write Node.js code directly in Elixir files.
  In the Node.js code, you have to export a function named `main` that takes
  an object as an argument and returns a value.

      export const main = ({x, y}) => x + y

  ## Examples

      iex> require Lux.NodeJS
      iex> Lux.NodeJS.nodejs variables: %{x: 40, y: 2} do
      ...>   ~JS'''
      ...>   export const main = ({x, y}) => x + y
      ...>   '''
      ...> end
      42

  ## Error Handling

  All public functions return `{:ok, result}` on success or `{:error, reason}`
  on failure. Possible error reasons include:

    * `:timeout` - Node.js execution exceeded the specified timeout
    * `:invalid_code` - The provided code is empty or invalid
    * `:invalid_package` - The package name is empty or invalid
    * `string()` - Other error messages from the Node.js runtime

  ## Timeout Behavior

  When a timeout occurs, the Node.js process may continue executing the code
  in the background. Subsequent calls will still work correctly as the module
  creates fresh execution contexts per call.
  """

  @type eval_option ::
          {:variables, map()}
          | {:timeout, pos_integer()}

  @type eval_options :: [eval_option()]

  @type import_result :: %{
          required(String.t()) => boolean() | String.t()
        }

  @module_path Application.app_dir(:lux, "priv/node")

  @doc """
  Evaluates Node.js code with optional variable bindings and other options.

  ## Options

    * `:variables` - A map of variables to bind in the Node.js context
    * `:timeout` - Timeout in milliseconds for Node.js execution

  ## Returns

    * `{:ok, result}` - Successfully evaluated, returns the result
    * `{:error, :timeout}` - Execution exceeded the timeout
    * `{:error, :invalid_code}` - Code is empty or invalid
    * `{:error, reason}` - Other error from the Node.js runtime

  ## Examples

      iex> Lux.NodeJS.eval("export const main = ({x}) => x * 2", variables: %{x: 21})
      {:ok, 42}

      iex> Lux.NodeJS.eval("export const main = () => 42", timeout: 5000)
      {:ok, 42}
  """
  @spec eval(String.t(), eval_options()) :: {:ok, term()} | {:error, term()}
  def eval(code, opts \\ []) do
    with :ok <- validate_code(code) do
      {variables, opts} = Keyword.pop(opts, :variables, %{})

      code
      |> do_eval(variables, opts, &NodeJS.call/3)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, "Call timed out."} -> {:error, :timeout}
        {:error, error} -> {:error, error}
      end
    end
  end

  @doc """
  Same as `eval/2`, but raises an error on failure.

  ## Examples

      iex> Lux.NodeJS.eval!("export const main = () => 42")
      42

      iex> Lux.NodeJS.eval!("invalid code")
      ** (NodeJS.Error) raises an error
  """
  @spec eval!(String.t(), eval_options()) :: term() | no_return()
  def eval!(code, opts \\ []) do
    {variables, opts} = Keyword.pop(opts, :variables, %{})
    do_eval(code, variables, opts, &NodeJS.call!/3)
  end

  @doc """
  Returns the module path for the Node.js runtime.

  ## Examples

      iex> Lux.NodeJS.module_path()
      "/path/to/lux/priv/node"
  """
  @spec module_path() :: String.t()
  def module_path, do: @module_path

  @doc false
  @spec child_spec(keyword()) :: :supervisor.child_spec()
  def child_spec(opts \\ []) do
    NodeJS.Supervisor.child_spec([path: module_path()] ++ opts)
  end

  @doc """
  Attempts to import a Node.js package.
  Currently, it will modify `priv/node/package.json` and `priv/node/package_lock.json` files.

  ## Options

    * `:update_lock_file` - Whether to update the lock file after importing the package (default: true)
    * `:timeout` - Timeout in milliseconds for Node.js execution

  ## Returns

    * `{:ok, %{"success" => true}}` - Package imported successfully
    * `{:error, :invalid_package}` - Package name is empty or invalid
    * `{:error, "Cannot import package: name"}` - Package not found
    * `{:error, reason}` - Other error from the Node.js runtime

  ## Examples

      iex> Lux.NodeJS.import_package("flatten", update_lock_file: false)
      {:ok, %{"success" => true}}

      iex> Lux.NodeJS.import_package("nonexistent-package-xyz")
      {:error, "Cannot import package: nonexistent-package-xyz"}
  """
  @spec import_package(String.t(), keyword()) ::
          {:ok, import_result()} | {:error, String.t()}
  def import_package(package_name, opts \\ []) when is_binary(package_name) do
    with :ok <- validate_package_name(package_name) do
      {update_lock_file, opts} = Keyword.pop(opts, :update_lock_file, true)

      {"lux.mjs", "importPackage"}
      |> NodeJS.call([package_name, %{update_lock_file: update_lock_file}], opts)
      |> handle_import_result(package_name)
    end
  end

  @doc """
  A macro for executing Node.js code with variable bindings.
  Node.js code should be wrapped in a sigil ~JS to bypass Elixir syntax checking.

  ## Examples

      iex> require Lux.NodeJS
      iex> Lux.NodeJS.nodejs variables: %{x: 21} do
      ...>   ~JS'''
      ...>   export const main = ({x}) => x * 2
      ...>   '''
      ...> end
      {:ok, 42}
  """
  defmacro nodejs(opts \\ [], do: {:sigil_JS, _, [{:<<>>, _, [code]}, []]}) do
    quote do
      Lux.NodeJS.eval(unquote(code), unquote(opts))
    end
  end

  @doc false
  defmacro sigil_JS({:<<>>, _meta, [string]}, _modifiers) do
    quote do: unquote(string)
  end

  # Private functions

  defp validate_code(code) when is_binary(code) do
    trimmed = String.trim(code)

    if trimmed == "" do
      {:error, :invalid_code}
    else
      :ok
    end
  end

  defp validate_code(_), do: {:error, :invalid_code}

  defp validate_package_name(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" -> {:error, "Cannot import package: empty name"}
      String.length(trimmed) > 214 -> {:error, "Package name exceeds 214 characters"}
      true -> :ok
    end
  end

  defp handle_import_result(result, package_name) do
    case result do
      {:ok, %{"success" => true} = res} ->
        {:ok, res}

      {:ok, %{"error" => "ERR_MODULE_NOT_FOUND"}} ->
        {:error, "Cannot import package: #{package_name}"}

      {:ok, %{"error" => error}} ->
        {:error, error}

      {:error, "Call timed out."} ->
        {:error, :timeout}

      {:error, error} ->
        {:error, error}
    end
  end

  defp do_eval(code, variables, opts, fun) do
    filename = create_file_name(code)

    with {:ok, filepath} <- ensure_module_path(filename),
         :ok <- File.write(filepath, code) do
      fun.({filename, "main"}, [variables], opts)
    end
  end

  defp ensure_module_path(filename) do
    filepath = Path.join(@module_path, filename)
    module_path = Path.dirname(filepath)

    if !File.exists?(module_path) do
      File.mkdir_p(module_path)
    end

    {:ok, filepath}
  end

  defp create_file_name(code) do
    hash = :sha |> :crypto.hash(code) |> Base.encode16(case: :lower)
    Path.join(["node_modules", "lux", "#{hash}.mjs"])
  end
end
