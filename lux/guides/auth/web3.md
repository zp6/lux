# Web3 Authentication

Lux provides built-in Web3 authentication using the **Sign-In with Ethereum (SIWE)** standard (EIP-4361). This allows users to authenticate using their Ethereum wallet, verifying ownership of an address through cryptographic signatures.

## Overview

The Web3 auth system consists of several modules:

| Module | Description |
|--------|-------------|
| `Lux.Auth.Web3` | Main authentication module (SIWE message construction & verification) |
| `Lux.Auth.Web3.Signature` | ECDSA secp256k1 signature recovery |
| `Lux.Auth.Web3.Session` | JWT-like token management |
| `Lux.Auth.Web3.RBAC` | Role-based access control |
| `Lux.Auth.Web3.Audit` | Authentication audit logging |

## Authentication Flow

```
1. Client requests a nonce
   GET /auth/nonce → "a1b2c3..."

2. Server generates and stores the nonce

3. Client constructs a SIWE message with the nonce

4. Client signs the message with their wallet (personal_sign / EIP-191)

5. Client sends the message + signature to the server
   POST /auth/verify { message, signature }

6. Server verifies:
   - Nonce is valid and unused
   - Message hasn't expired
   - Signature recovers to the claimed address

7. Server creates a session and returns a token
```

## Quick Start

### Generating a Nonce

```elixir
{:ok, nonce} = Lux.Auth.Web3.generate_nonce()
```

Nonces are single-use, expire after 5 minutes, and are stored in an ETS-backed cache.

### Building a SIWE Message

```elixir
message = Lux.Auth.Web3.build_siwe_message(%{
  domain: "myapp.com",
  address: "0x71C7656EC7ab88b098defB751B7401B5f6d8976F",
  statement: "Sign in to MyApp",
  nonce: nonce,
  chain_id: 1
})
```

### Authenticating

```elixir
{:ok, session} = Lux.Auth.Web3.authenticate(signed_message, signature)
# session.token → JWT-like token for subsequent requests
# session.address → verified Ethereum address
# session.expires_at → token expiry timestamp
```

### Validating Sessions

```elixir
case Lux.Auth.Web3.validate_session(token) do
  {:ok, session} -> # Valid session
  {:error, :session_expired} -> # Token expired
  {:error, :session_revoked} -> # Token was revoked
end
```

## Session Management

Sessions use HMAC-SHA256 signed tokens with the following claims:

- `sub` - Ethereum address
- `chain_id` - Blockchain chain ID
- `domain` - Requesting domain
- `iat` - Issued at (timestamp)
- `exp` - Expiration time (timestamp)
- `jti` - Unique token identifier

### Configuration

Set a custom signing key in your config:

```elixir
config :lux, :web3_auth_signing_key, "your-secret-key-here"
```

Default session TTL is 8 hours. Customize when creating:

```elixir
{:ok, session} = Session.create(claims, ttl: 7200) # 2 hours
```

### Refresh & Revocation

```elixir
# Extend a session (creates new token, revokes old)
{:ok, new_session} = Lux.Auth.Web3.refresh_session(old_token)

# Explicitly revoke
:ok = Lux.Auth.Web3.revoke_session(token)
```

## Role-Based Access Control (RBAC)

Three built-in roles:

| Role | Permissions | Level |
|------|------------|-------|
| `:admin` | read, write, delete, manage | 3 |
| `:user` | read, write | 2 |
| `:viewer` | read | 1 |

### Assigning Roles

```elixir
Lux.Auth.Web3.RBAC.assign_role("0x...", :user)
```

### Checking Permissions

```elixir
case Lux.Auth.Web3.RBAC.check_permission("0x...", :write, :trades) do
  :ok -> # Access granted
  {:error, :forbidden} -> # Access denied
end
```

### Resource-Level Overrides

Grant specific permissions that override role defaults:

```elixir
# Grant write access to a specific resource for a viewer
Lux.Auth.Web3.RBAC.grant_resource_permission("0x...", :reports, :write)
```

### Token-Gated Access

```elixir
Lux.Auth.Web3.RBAC.check_token_gate("0x...", %{
  min_role_level: 2,
  min_balance: 100,
  token: "USDC"
})
```

## Audit Logging

All authentication events are automatically logged:

- `:auth_success` - Successful sign-in
- `:auth_failure` - Failed attempt (includes reason)
- `:session_created` - New session
- `:session_revoked` - Revoked session
- `:permission_denied` - RBAC denial

### Querying Events

```elixir
# Recent events
events = Lux.Auth.Web3.Audit.list_events(limit: 20)

# Filter by type
failures = Lux.Auth.Web3.Audit.list_events(type: :auth_failure)

# Events for a specific address
events = Lux.Auth.Web3.Audit.events_for_address("0x...", limit: 10)
```

### Rate Limiting

Built-in rate limiting tracks failed authentication attempts:

- **Window**: 5 minutes
- **Max failures**: 5

```elixir
case Lux.Auth.Web3.Audit.check_rate_limit("0x...") do
  :ok -> # Under limit, proceed
  {:error, :rate_limited} -> # Too many failures, reject
end
```

## Dependencies

The Web3 auth module relies on:

- `ex_secp256k1` - ECDSA signature recovery (already in Lux dependencies)
- `jason` - JSON encoding for session tokens
- `:crypto` - HMAC-SHA256 for token signing

No additional dependencies need to be added.

## Integration with Phoenix

Example controller:

```elixir
defmodule MyAppWeb.AuthController do
  use MyAppWeb, :controller

  def nonce(conn, _params) do
    {:ok, nonce} = Lux.Auth.Web3.generate_nonce()
    json(conn, %{nonce: nonce})
  end

  def verify(conn, %{"message" => message, "signature" => signature}) do
    case Lux.Auth.Web3.authenticate(message, signature) do
      {:ok, session} ->
        json(conn, %{token: session.token, address: session.address})

      {:error, reason} ->
        conn
        |> put_status(401)
        |> json(%{error: reason})
    end
  end

  def me(conn, _params) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Lux.Auth.Web3.validate_session(token) do
          {:ok, session} -> json(conn, %{address: session.address})
          {:error, _} -> conn |> put_status(401) |> json(%{error: "unauthorized"})
        end

      _ ->
        conn |> put_status(401) |> json(%{error: "missing token"})
    end
  end
end
```

## EIP-4361 Compliance

This implementation follows [EIP-4361: Sign-In with Ethereum](https://eips.ethereum.org/EIPS/eip-4361):

- ✅ SIWE message format
- ✅ EIP-191 personal_sign prefix
- ✅ Nonce-based replay protection
- ✅ Domain binding
- ✅ Chain ID verification
- ✅ Timestamp validation (issued_at, expiration_time, not_before)
- ✅ Resource URI support
