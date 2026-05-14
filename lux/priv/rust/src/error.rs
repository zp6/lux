//! # Error Handling
//!
//! Provides utilities for converting Rust `Result` types into Elixir-style
//! `{:ok, value}` and `{:error, reason}` tuples.

use rustler::{Atom, Encoder, Env, NifResult, Term};

/// Wraps a successful value in `{:ok, value}`.
///
/// ## Example (Rust)
///
/// ```rust
/// use crate::error;
///
/// let result = error::ok(env, 42.encode(env));
/// // Returns {:ok, 42} to Elixir
/// ```
pub fn ok<'a>(env: Env<'a>, value: Term<'a>) -> Term<'a> {
    let ok_atom = Atom::from_bytes(env, b"ok").unwrap();
    (ok_atom, value).encode(env)
}

/// Wraps an error reason in `{:error, reason}`.
///
/// ## Example (Rust)
///
/// ```rust
/// use crate::error;
///
/// let result = error::error(env, "something went wrong".encode(env));
/// // Returns {:error, "something went wrong"} to Elixir
/// ```
pub fn error<'a>(env: Env<'a>, reason: Term<'a>) -> Term<'a> {
    let error_atom = Atom::from_bytes(env, b"error").unwrap();
    (error_atom, reason).encode(env)
}

/// Converts a `Result<T, String>` into an Elixir `{:ok, term}` or `{:error, string}`.
pub fn result_to_term<'a, T: Encoder>(env: Env<'a>, res: Result<T, String>) -> Term<'a> {
    match res {
        Ok(val) => ok(env, val.encode(env)),
        Err(reason) => error(env, reason.encode(env)),
    }
}
