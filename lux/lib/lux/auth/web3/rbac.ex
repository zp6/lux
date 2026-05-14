defmodule Lux.Auth.Web3.RBAC do
  @moduledoc """
  Role-Based Access Control for Web3 authentication.

  Provides role definitions, permission checking, and token-gated access
  for Ethereum wallet addresses.

  ## Roles

    * `:admin` - Full access to all resources
    * `:user` - Standard access with write capabilities
    * `:viewer` - Read-only access

  ## Usage

      # Assign a role
      Lux.Auth.Web3.RBAC.assign_role("0xabc...", :user)

      # Check permission
      :ok = Lux.Auth.Web3.RBAC.check_permission("0xabc...", :write, :trades)

      # Token-gated access
      :ok = Lux.Auth.Web3.RBAC.check_token_gate("0xabc...", %{min_balance: 100, token: "USDC"})
  """

  @type role :: :admin | :user | :viewer
  @type permission :: :read | :write | :delete | :manage
  @type resource :: atom()

  @roles %{
    admin: %{
      permissions: [:read, :write, :delete, :manage],
      level: 3
    },
    user: %{
      permissions: [:read, :write],
      level: 2
    },
    viewer: %{
      permissions: [:read],
      level: 1
    }
  }

  @default_role :viewer

  @doc """
  Returns the list of available roles.
  """
  @spec roles() :: [role()]
  def roles, do: Map.keys(@roles)

  @doc """
  Returns the permissions associated with a role.
  """
  @spec role_permissions(role()) :: [permission()]
  def role_permissions(role) do
    case Map.get(@roles, role) do
      nil -> []
      %{permissions: perms} -> perms
    end
  end

  @doc """
  Returns the numeric level of a role (higher = more access).
  """
  @spec role_level(role()) :: non_neg_integer()
  def role_level(role) do
    case Map.get(@roles, role) do
      nil -> 0
      %{level: level} -> level
    end
  end

  @doc """
  Assigns a role to an Ethereum address.

  Role assignments are stored in an ETS table and persist for the
  lifetime of the BEAM VM.
  """
  @spec assign_role(String.t(), role()) :: :ok
  def assign_role(address, role) when role in @roles |> Map.keys() do
    ensure_rbac_table()
    normalized = normalize_address(address)
    :ets.insert(:web3_rbac, {normalized, role})
    :ok
  end

  @doc """
  Returns the role assigned to an address.
  Defaults to `:viewer` if no role has been explicitly assigned.
  """
  @spec get_role(String.t()) :: role()
  def get_role(address) do
    ensure_rbac_table()
    normalized = normalize_address(address)

    case :ets.lookup(:web3_rbac, normalized) do
      [{^normalized, role}] -> role
      [] -> @default_role
    end
  end

  @doc """
  Checks if an address has a specific permission on a resource.

  Returns `:ok` if the permission is granted, `{:error, :forbidden}` otherwise.

  Resource-level overrides can be applied via `grant_resource_permission/3`.
  """
  @spec check_permission(String.t(), permission(), resource()) :: :ok | {:error, :forbidden}
  def check_permission(address, permission, resource \\ :default) do
    ensure_rbac_table()
    normalized = normalize_address(address)

    # Check resource-specific permissions first
    case get_resource_permission(normalized, resource, permission) do
      :granted -> :ok
      :denied -> {:error, :forbidden}
      :not_found ->
        # Fall back to role-based permissions
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
  This overrides the role-based permission for that resource.
  """
  @spec grant_resource_permission(String.t(), resource(), permission()) :: :ok
  def grant_resource_permission(address, resource, permission) do
    ensure_rbac_table()
    normalized = normalize_address(address)
    key = {normalized, resource}
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
  """
  @spec revoke_resource_permission(String.t(), resource(), permission()) :: :ok
  def revoke_resource_permission(address, resource, permission) do
    ensure_rbac_table()
    normalized = normalize_address(address)
    key = {normalized, resource}

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

  Token gates define minimum requirements for accessing a resource,
  such as minimum token balance or NFT ownership.

  ## Gate Parameters

    * `:min_balance` - Minimum token balance required
    * `:token` - The token contract address or symbol
    * `:nft_collection` - NFT collection address to check ownership
    * `:custom` - Custom gate check function `{module, function, args}`

  > #### Note {: .info}
  > Token gate checks are currently implemented as role-based checks.
  > On-chain verification would require integration with an RPC provider.
  """
  @spec check_token_gate(String.t(), map()) :: :ok | {:error, :gate_not_met}
  def check_token_gate(address, gate_spec) do
    ensure_rbac_table()
    normalized = normalize_address(address)
    gate_key = {:gate, normalized, :erlang.phash2(gate_spec)}

    case :ets.lookup(:web3_rbac_gates, gate_key) do
      [{^gate_key, :granted}] -> :ok
      [{^gate_key, :denied}] -> {:error, :gate_not_met}
      [] ->
        # For now, check if address has sufficient role level
        # In production, this would check on-chain balance/ownership
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
  Clears all RBAC data. Primarily for testing.
  """
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
