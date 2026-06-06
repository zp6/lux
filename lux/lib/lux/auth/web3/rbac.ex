defmodule Lux.Auth.Web3.RBAC do
  @moduledoc """
  Role-Based Access Control for Web3 authentication.

  Provides role definitions, permission checking, and token-gated access
  for Ethereum wallet addresses.

  ## Roles

    * `:admin` - Full access to all resources
    * `:user` - Standard access with write capabilities
    * `:viewer` - Read-only access

  ## Cache Invalidation

  RBAC caches for token gates are automatically invalidated when:
    * A role is assigned or changed via `assign_role/2`
    * A resource permission is granted or revoked
    * Token-gate cache is explicitly cleared via `invalidate_token_gate_cache/1`
    * All caches cleared via `invalidate_all_token_gate_caches/0`
    * External state changes via `invalidate_caches_for_state_change/2`
  """

  @type role :: :admin | :user | :viewer
  @type permission :: :read | :write | :delete | :manage
  @type resource :: atom()

  @roles %{
    admin: %{permissions: [:read, :write, :delete, :manage], level: 3},
    user: %{permissions: [:read, :write], level: 2},
    viewer: %{permissions: [:read], level: 1}
  }

  @default_role :viewer

  @spec roles() :: [role()]
  def roles, do: Map.keys(@roles)

  @spec role_permissions(role()) :: [permission()]
  def role_permissions(role) do
    case Map.get(@roles, role) do
      nil -> []
      %{permissions: perms} -> perms
    end
  end

  @spec role_level(role()) :: non_neg_integer()
  def role_level(role) do
    case Map.get(@roles, role) do
      nil -> 0
      %{level: level} -> level
    end
  end

  @doc """
  Assigns a role to an Ethereum address.

  Also invalidates any cached token-gate results for this address.
  """
  @spec assign_role(String.t(), role()) :: :ok
  def assign_role(address, role) when role in @roles |> Map.keys() do
    ensure_rbac_table()
    normalized = normalize_address(address)

    # Invalidate token gate cache on role change
    invalidate_token_gate_cache(normalized)

    :ets.insert(:web3_rbac, {normalized, role})
    :ok
  end

  @spec get_role(String.t()) :: role()
  def get_role(address) do
    ensure_rbac_table()
    normalized = normalize_address(address)

    case :ets.lookup(:web3_rbac, normalized) do
      [{^normalized, role}] -> role
      [] -> @default_role
    end
  end

  @spec check_permission(String.t(), permission(), resource()) :: :ok | {:error, :forbidden}
  def check_permission(address, permission, resource \\ :default) do
    ensure_rbac_table()
    normalized = normalize_address(address)

    case get_resource_permission(normalized, resource, permission) do
      :granted -> :ok
      :denied -> {:error, :forbidden}
      :not_found ->
        role = get_role(address)

        if permission in role_permissions(role) do
          :ok
        else
          {:error, :forbidden}
        end
    end
  end

  @doc """
  Grants a specific permission for a resource to an address.

  Also invalidates any cached token-gate results for this address.
  """
  @spec grant_resource_permission(String.t(), resource(), permission()) :: :ok
  def grant_resource_permission(address, resource, permission) do
    ensure_rbac_table()
    normalized = normalize_address(address)
    key = {normalized, resource}

    invalidate_token_gate_cache(normalized)

    current = :ets.lookup(:web3_rbac_resources, key)

    perms =
      case current do
        [{^key, perms}] -> MapSet.put(perms, permission)
        [] -> MapSet.new([permission])
      end

    :ets.insert(:web3_rbac_resources, {key, perms})
    :ok
  end

  @doc """
  Revokes a specific permission for a resource from an address.

  Also invalidates any cached token-gate results for this address.
  """
  @spec revoke_resource_permission(String.t(), resource(), permission()) :: :ok
  def revoke_resource_permission(address, resource, permission) do
    ensure_rbac_table()
    normalized = normalize_address(address)
    key = {normalized, resource}

    invalidate_token_gate_cache(normalized)

    case :ets.lookup(:web3_rbac_resources, key) do
      [{^key, perms}] ->
        new_perms = MapSet.delete(perms, permission)

        if MapSet.size(new_perms) == 0 do
          :ets.delete(:web3_rbac_resources, key)
        else
          :ets.insert(:web3_rbac_resources, {key, new_perms})
        end

      [] ->
        :ok
    end
  end

  @doc """
  Checks token-gated access for an address.

  Supports two modes:
  1. **On-chain verification** (preferred): When gate spec has `:type` field,
     delegates to `Lux.Auth.Web3.TokenGate` for real on-chain checks.
  2. **Role-level fallback** (legacy): Checks role level against `:min_role_level`.

  Results are cached per address+gate_spec. Cache is invalidated on role/permission/state changes.
  """
  @spec check_token_gate(String.t(), map()) :: :ok | {:error, :gate_not_met}
  def check_token_gate(address, %{type: _type} = gate_spec) do
    ensure_rbac_table()
    normalized = normalize_address(address)

    case Lux.Auth.Web3.TokenGate.check(normalized, gate_spec) do
      :ok ->
        cache_gate_result(normalized, gate_spec, :granted)
        :ok

      {:error, _} = error ->
        cache_gate_result(normalized, gate_spec, :denied)
        error
    end
  end

  def check_token_gate(address, gate_spec) do
    ensure_rbac_table()
    normalized = normalize_address(address)
    gate_key = {:gate, normalized, :erlang.phash2(gate_spec)}

    case :ets.lookup(:web3_rbac_gates, gate_key) do
      [{^gate_key, :granted}] -> :ok
      [{^gate_key, :denied}] -> {:error, :gate_not_met}
      [] ->
        role = get_role(address)
        min_level = Map.get(gate_spec, :min_role_level, 1)

        if role_level(role) >= min_level do
          :ets.insert(:web3_rbac_gates, {gate_key, :granted})
          :ok
        else
          :ets.insert(:web3_rbac_gates, {gate_key, :denied})
          {:error, :gate_not_met}
        end
    end
  end

  @doc """
  Invalidates all cached token-gate results for a specific address.
  """
  @spec invalidate_token_gate_cache(String.t()) :: :ok
  def invalidate_token_gate_cache(address) do
    normalized = if is_binary(address), do: String.downcase(address), else: address
    ensure_rbac_table()

    try do
      # :ets.match_delete treats :_ as atom literal, not wildcard.
      # Use :ets.select_delete with match spec that binds the address portion.
      :ets.select_delete(
        :web3_rbac_gates,
        [{{:{:gate, :"$1", :"$2"}, :"$3"}, [{:==, :"$1", normalized}], [true]}]
      )
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @doc """
  Invalidates all cached token-gate results globally.
  """
  @spec invalidate_all_token_gate_caches() :: :ok
  def invalidate_all_token_gate_caches do
    ensure_rbac_table()

    case :ets.whereis(:web3_rbac_gates) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(:web3_rbac_gates)
    end

    :ok
  end

  @doc """
  Invalidates caches for token-balance or provider state changes.

  ## Parameters

    * `scope` - `:address` for one address, `:all` for global
    * `address` - The address (required when scope is `:address`)
  """
  @spec invalidate_caches_for_state_change(:address | :all, String.t() | nil) :: :ok
  def invalidate_caches_for_state_change(:address, address) when is_binary(address) do
    invalidate_token_gate_cache(address)
  end

  def invalidate_caches_for_state_change(:all, _address) do
    invalidate_all_token_gate_caches()
  end

  @spec reset!() :: :ok
  def reset! do
    for table <- [:web3_rbac, :web3_rbac_resources, :web3_rbac_gates] do
      case :ets.whereis(table) do
        :undefined -> :ok
        _ref -> :ets.delete(table)
      end
    end

    :ok
  end

  # --- Private Helpers ---

  defp ensure_rbac_table do
    for table <- [:web3_rbac, :web3_rbac_resources, :web3_rbac_gates] do
      case :ets.whereis(table) do
        :undefined -> :ets.new(table, [:set, :public, :named_table])
        _ref -> :ok
      end
    end
  end

  defp cache_gate_result(normalized, gate_spec, result) do
    gate_key = {:gate, normalized, :erlang.phash2(gate_spec)}
    :ets.insert(:web3_rbac_gates, {gate_key, result})
  end

  defp get_resource_permission(normalized, resource, permission) do
    key = {normalized, resource}

    case :ets.lookup(:web3_rbac_resources, key) do
      [{^key, perms}] ->
        if MapSet.member?(perms, permission), do: :granted, else: :denied

      [] ->
        :not_found
    end
  end

  defp normalize_address(address), do: String.downcase(address)
end
