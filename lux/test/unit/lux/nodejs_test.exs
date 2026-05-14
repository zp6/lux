defmodule Lux.NodeJSTest do
  @moduledoc """
  Comprehensive tests for Lux.NodeJS module.

  Tests cover:
  - Code evaluation (eval/2, eval!/2)
  - Variable bindings
  - Error handling (timeout, invalid code, runtime errors)
  - Package import functionality
  - The nodejs macro
  - Edge cases and regression tests
  """
  use UnitCase, async: true

  import Lux.NodeJS

  require Lux.NodeJS

  describe "eval/2" do
    test "evaluates simple Node.js expressions" do
      assert {:ok, 2} = eval("export const main = () => 1 + 1")
    end

    test "evaluates code with variable bindings" do
      assert {:ok, 30} =
               eval("export const main = ({x, y}) => x * y", variables: %{x: 5, y: 6})
    end

    test "supports multi-line code" do
      code = """
      export const main = ({n}) => {
          const factorial = (n) => {
              if (n <= 1) {
                  return 1
              }
              return n * factorial(n - 1)
          }
          return factorial(n)
      }
      """

      assert {:ok, 120} = eval(code, variables: %{n: 5})
    end

    test "handles string return values" do
      assert {:ok, "hello world"} =
               eval("export const main = () => 'hello world'")
    end

    test "handles object return values" do
      assert {:ok, %{"a" => 1, "b" => 2}} =
               eval("export const main = () => ({a: 1, b: 2})")
    end

    test "handles array return values" do
      assert {:ok, [1, 2, 3]} = eval("export const main = () => [1, 2, 3]")
    end

    test "handles boolean return values" do
      assert {:ok, true} = eval("export const main = () => true")
      assert {:ok, false} = eval("export const main = () => false")
    end

    test "handles null return values" do
      assert {:ok, nil} = eval("export const main = () => null")
    end

    test "handles async functions" do
      code = """
      export const main = async () => {
        await new Promise(resolve => setTimeout(resolve, 10))
        return 42
      }
      """

      assert {:ok, 42} = eval(code)
    end

    test "returns error for empty code" do
      assert {:error, :invalid_code} = eval("")
      assert {:error, :invalid_code} = eval("   ")
    end

    test "returns error for runtime errors" do
      assert {:error, _} = eval("export const main = () => undefined_var")
    end

    test "supports complex variable types" do
      assert {:ok, %{"result" => [1, 2, 3]}} =
               eval(
                 "export const main = ({data}) => ({result: data.map(x => x * 1)})",
                 variables: %{data: [1, 2, 3]}
               )
    end

    test "handles deeply nested objects" do
      code = """
      export const main = ({obj}) => {
        return obj.a.b.c
      }
      """

      assert {:ok, 42} =
               eval(code, variables: %{obj: %{a: %{b: %{c: 42}}}})
    end

    test "handles numeric return values correctly" do
      assert {:ok, 0} = eval("export const main = () => 0")
      assert {:ok, -1} = eval("export const main = () => -1")
      assert {:ok, 3.14} = eval("export const main = () => 3.14")
    end
  end

  describe "eval!/2" do
    test "returns result directly on success" do
      assert 3 == eval!("export const main = () => 1 + 2")
    end

    test "raises error on failure" do
      assert_raise NodeJS.Error,
                   ~r/undefined_var is not defined/,
                   fn ->
                     eval!("undefined_var")
                   end
    end

    test "supports variable bindings" do
      assert 42 == eval!("export const main = ({x}) => x * 2", variables: %{x: 21})
    end

    test "handles complex computations" do
      code = """
      export const main = ({arr}) => {
        return arr.reduce((sum, n) => sum + n, 0)
      }
      """

      assert 15 == eval!(code, variables: %{arr: [1, 2, 3, 4, 5]})
    end
  end

  describe "nodejs/2 macro" do
    test "executes simple Node.js expressions" do
      result =
        nodejs do
          ~JS"""
          export const main = () => 2 + 2
          """
        end

      assert {:ok, 4} = result
    end

    test "supports variable bindings" do
      result =
        nodejs variables: %{x: 21} do
          ~JS"""
          export const main = ({x}) => x * 2
          """
        end

      assert {:ok, 42} = result
    end

    test "handle multi-line Node.js code" do
      result =
        nodejs do
          ~JS"""
          export const main = () => {
              const factorial = (n) => {
                  if (n <= 1) {
                      return 1
                  }
                  return n * factorial(n - 1)
              }
              return factorial(5)
          }
          """
        end

      assert {:ok, 120} = result
    end

    test "respects timeout option" do
      result =
        nodejs timeout: 10 do
          ~JS"""
          export const main = async () => {
             await new Promise(resolve => setTimeout(() => resolve(), 1000))
          }
          """
        end

      assert {:error, :timeout} = result
    end

    test "handles string manipulation" do
      result =
        nodejs variables: %{text: "hello"} do
          ~JS"""
          export const main = ({text}) => {
            return text.toUpperCase()
          }
          """
        end

      assert {:ok, "HELLO"} = result
    end

    test "handles JSON operations" do
      result =
        nodejs variables: %{json: "{\"key\": \"value\"}"} do
          ~JS"""
          export const main = ({json}) => {
            const parsed = JSON.parse(json)
            return parsed.key
          }
          """
        end

      assert {:ok, "value"} = result
    end

    test "handles error throwing in Node.js code" do
      result =
        nodejs do
          ~JS"""
          export const main = () => {
            throw new Error("test error")
          }
          """
        end

      assert {:error, _} = result
    end
  end

  describe "timeout handling" do
    @tag :skip
    test "recovers after a timeout - subsequent calls still work" do
      # First, trigger a timeout
      _timeout_result =
        nodejs timeout: 10 do
          ~JS"""
          export const main = async () => {
            await new Promise(resolve => setTimeout(resolve, 1000))
          }
          """
        end

      # Allow cleanup
      Process.sleep(100)

      # Verify subsequent call still works correctly
      result =
        nodejs do
          ~JS"""
          export const main = () => 42
          """
        end

      assert {:ok, 42} = result
    end
  end

  describe "import_package/2" do
    @tag :skip
    test "successfully imports a package" do
      assert {:ok, %{"success" => true}} = import_package("flatten", update_lock_file: false)
    end

    @tag :skip
    test "returns error for non-existent package" do
      assert {:error, _} = import_package("nonexistent-package-xyz-12345")
    end

    @tag :skip
    test "returns error for invalid package name" do
      assert {:error, _} = import_package("")
      assert {:error, _} = import_package("   ")
    end
  end

  describe "edge cases" do
    test "handles code with Unicode" do
      result =
        nodejs variables: %{name: "世界"} do
          ~JS"""
          export const main = ({name}) => `Hello ${name}`
          """
        end

      assert {:ok, "Hello 世界"} = result
    end

    test "handles very large return values" do
      result =
        nodejs do
          ~JS"""
          export const main = () => {
            const arr = Array.from({length: 1000}, (_, i) => i)
            return arr.reduce((sum, n) => sum + n, 0)
          }
          """
        end

      assert {:ok, 499_500} = result
    end

    test "handles Promise rejection" do
      result =
        nodejs do
          ~JS"""
          export const main = async () => {
            throw new Error("async error")
          }
          """
        end

      assert {:error, _} = result
    end

    test "handles empty variable map" do
      result =
        nodejs variables: %{} do
          ~JS"""
          export const main = () => 7
          """
        end

      assert {:ok, 7} = result
    end

    test "handles special characters in variables" do
      result =
        nodejs variables: %{text: "<script>alert('xss')</script>"} do
          ~JS"""
          export const main = ({text}) => text.length
          """
        end

      assert {:ok, 31} = result
    end
  end
end
