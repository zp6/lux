//! # Primitive Type Conversions
//!
//! Handles bidirectional conversion between Elixir primitive types
//! and Rust equivalents: integers, floats, strings, booleans, and atoms.

use rustler::{Atom, Decoder, Encoder, Env, NifResult, Term};
use std::fmt;

/// Represents an Elixir primitive value that can be converted to/from Rust.
#[derive(Debug, Clone, PartialEq)]
pub enum Primitive {
    Integer(i64),
    Float(f64),
    String(String),
    Boolean(bool),
    Atom(String),
    Nil,
}

impl Primitive {
    /// Convert from an Elixir term into a Primitive value.
    ///
    /// Tries decoding in order: bool → i64 → f64 → string → atom → nil.
    pub fn from_term(term: Term) -> NifResult<Self> {
        // Boolean must be checked before integer (true/false are also atoms)
        if let Ok(b) = term.decode::<bool>() {
            return Ok(Primitive::Boolean(b));
        }
        if let Ok(i) = term.decode::<i64>() {
            return Ok(Primitive::Integer(i));
        }
        if let Ok(f) = term.decode::<f64>() {
            return Ok(Primitive::Float(f));
        }
        if let Ok(s) = term.decode::<String>() {
            return Ok(Primitive::String(s));
        }
        // Try atom
        if let Ok(atom) = term.decode::<Atom>() {
            let env = term.get_env();
            let name = atom
                .to_term(env)
                .atom_to_string()
                .unwrap_or_else(|_| "unknown".to_string());
            if name == "nil" {
                return Ok(Primitive::Nil);
            }
            return Ok(Primitive::Atom(name));
        }
        // Try nil directly
        if let Ok(_nil_term) = term.decode::<Option<Term>>() {
            return Ok(Primitive::Nil);
        }

        Err(rustler::Error::RaiseAtom("cannot_decode_primitive"))
    }

    /// Encode this Primitive value back into an Elixir term.
    pub fn encode_term<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Primitive::Integer(i) => i.encode(env),
            Primitive::Float(f) => f.encode(env),
            Primitive::String(s) => s.encode(env),
            Primitive::Boolean(b) => b.encode(env),
            Primitive::Atom(name) => {
                // Best-effort atom creation
                match Atom::from_bytes(env, name.as_bytes()) {
                    Ok(a) => a.encode(env),
                    Err(_) => name.encode(env), // fallback to string
                }
            }
            Primitive::Nil => {
                Atom::from_bytes(env, b"nil")
                    .unwrap_or_else(|_| panic!("nil atom creation failed"))
                    .encode(env)
            }
        }
    }

    /// Returns the type name as a string (for introspection).
    pub fn type_name(&self) -> &'static str {
        match self {
            Primitive::Integer(_) => "integer",
            Primitive::Float(_) => "float",
            Primitive::String(_) => "string",
            Primitive::Boolean(_) => "boolean",
            Primitive::Atom(_) => "atom",
            Primitive::Nil => "nil",
        }
    }

    /// Try to convert to i64.
    pub fn as_integer(&self) -> Option<i64> {
        match self {
            Primitive::Integer(i) => Some(*i),
            Primitive::Float(f) if f.fract() == 0.0 => Some(*f as i64),
            _ => None,
        }
    }

    /// Try to convert to f64.
    pub fn as_float(&self) -> Option<f64> {
        match self {
            Primitive::Float(f) => Some(*f),
            Primitive::Integer(i) => Some(*i as f64),
            _ => None,
        }
    }

    /// Try to convert to String.
    pub fn as_string(&self) -> Option<String> {
        match self {
            Primitive::String(s) => Some(s.clone()),
            Primitive::Atom(a) => Some(a.clone()),
            Primitive::Integer(i) => Some(i.to_string()),
            Primitive::Float(f) => Some(f.to_string()),
            Primitive::Boolean(b) => Some(b.to_string()),
            Primitive::Nil => Some("nil".to_string()),
        }
    }

    /// Try to convert to bool.
    pub fn as_boolean(&self) -> Option<bool> {
        match self {
            Primitive::Boolean(b) => Some(*b),
            _ => None,
        }
    }
}

impl fmt::Display for Primitive {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Primitive::Integer(i) => write!(f, "{}", i),
            Primitive::Float(fl) => write!(f, "{}", fl),
            Primitive::String(s) => write!(f, "\"{}\"", s),
            Primitive::Boolean(b) => write!(f, "{}", b),
            Primitive::Atom(a) => write!(f, ":{}", a),
            Primitive::Nil => write!(f, "nil"),
        }
    }
}

/// NIF: Decode an Elixir term into a typed primitive descriptor.
/// Returns `{:ok, {type_name, value}}` or `{:error, reason}`.
#[rustler::nif]
pub fn decode_primitive(term: Term) -> NifResult<Term> {
    let env = term.get_env();
    let prim = Primitive::from_term(term)?;
    let type_name = prim.type_name();

    let encoded = match &prim {
        Primitive::Integer(i) => i.encode(env),
        Primitive::Float(f) => f.encode(env),
        Primitive::String(s) => s.encode(env),
        Primitive::Boolean(b) => b.encode(env),
        Primitive::Atom(a) => a.encode(env),
        Primitive::Nil => "nil".encode(env),
    };

    let ok_atom = Atom::from_bytes(env, b"ok").unwrap();
    Ok((ok_atom, (type_name, encoded)).encode(env))
}

/// NIF: Encode a typed primitive back into an Elixir term.
/// Takes `{type_name, value}` and returns the native Elixir term.
#[rustler::nif]
pub fn encode_primitive(tuple: Term) -> NifResult<Term> {
    let env = tuple.get_env();
    let (type_name, value): (String, Term) = tuple.decode()?;
    let prim = match type_name.as_str() {
        "integer" => {
            let i: i64 = value.decode()?;
            Primitive::Integer(i)
        }
        "float" => {
            let f: f64 = value.decode()?;
            Primitive::Float(f)
        }
        "string" => {
            let s: String = value.decode()?;
            Primitive::String(s)
        }
        "boolean" => {
            let b: bool = value.decode()?;
            Primitive::Boolean(b)
        }
        "atom" => {
            let s: String = value.decode()?;
            Primitive::Atom(s)
        }
        "nil" => Primitive::Nil,
        other => {
            return Err(rustler::Error::RaiseTerm(Box::new(format!(
                "unknown primitive type: {}",
                other
            ))));
        }
    };
    Ok(prim.encode_term(env))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_integer_type_name() {
        assert_eq!(Primitive::Integer(42).type_name(), "integer");
    }

    #[test]
    fn test_float_as_float() {
        assert_eq!(Primitive::Float(3.14).as_float(), Some(3.14));
    }

    #[test]
    fn test_integer_as_float() {
        assert_eq!(Primitive::Integer(5).as_float(), Some(5.0));
    }

    #[test]
    fn test_boolean_display() {
        assert_eq!(format!("{}", Primitive::Boolean(true)), "true");
    }

    #[test]
    fn test_nil_display() {
        assert_eq!(format!("{}", Primitive::Nil), "nil");
    }

    #[test]
    fn test_atom_display() {
        assert_eq!(format!("{}", Primitive::Atom("hello".into())), ":hello");
    }
}
