//! # Elixir Atom ↔ Rust Enum Conversion
//!
//! Provides bidirectional conversion between Elixir atoms and Rust enums.
//! This enables type-safe enum handling across the NIF boundary.

use rustler::{Atom, Encoder, Env, NifResult, Term};
use std::fmt;
use std::str::FromStr;

/// A dynamic enum value that can be converted to/from Elixir atoms.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct EnumValue {
    pub variant: String,
}

impl EnumValue {
    /// Create a new enum value from a variant name.
    pub fn new(variant: &str) -> Self {
        EnumValue {
            variant: variant.to_string(),
        }
    }

    /// Convert to an Elixir atom.
    pub fn to_atom<'a>(&self, env: Env<'a>) -> NifResult<Atom> {
        Atom::from_bytes(env, self.variant.as_bytes())
            .map_err(|_| rustler::Error::RaiseTerm(Box::new(format!(
                "cannot create atom for variant: {}",
                self.variant
            ))))
    }

    /// Convert from an Elixir atom.
    pub fn from_atom(atom: Atom, env: Env) -> NifResult<Self> {
        let name = atom
            .to_term(env)
            .atom_to_string()
            .map_err(|_| rustler::Error::RaiseAtom("cannot_convert_atom"))?;
        Ok(EnumValue { variant: name })
    }

    /// Convert from an Elixir term (tries atom, then string).
    pub fn from_term(term: Term) -> NifResult<Self> {
        let env = term.get_env();
        if let Ok(atom) = term.decode::<Atom>() {
            return EnumValue::from_atom(atom, env);
        }
        if let Ok(s) = term.decode::<String>() {
            return Ok(EnumValue { variant: s });
        }
        Err(rustler::Error::RaiseAtom("not_an_atom_or_string"))
    }

    /// Encode as an Elixir atom term.
    pub fn encode_term<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self.to_atom(env) {
            Ok(atom) => atom.encode(env),
            Err(_) => self.variant.encode(env), // fallback to string
        }
    }
}

impl fmt::Display for EnumValue {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, ":{}", self.variant)
    }
}

impl FromStr for EnumValue {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let variant = s.trim_start_matches(':');
        if variant.is_empty() {
            return Err("empty variant name".to_string());
        }
        Ok(EnumValue {
            variant: variant.to_string(),
        })
    }
}

/// Pre-defined enum types commonly used in Lux.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SignalStatus {
    Pending,
    Active,
    Completed,
    Failed,
    Cancelled,
}

impl SignalStatus {
    /// Convert to Elixir atom name.
    pub fn to_atom_name(&self) -> &'static str {
        match self {
            SignalStatus::Pending => "pending",
            SignalStatus::Active => "active",
            SignalStatus::Completed => "completed",
            SignalStatus::Failed => "failed",
            SignalStatus::Cancelled => "cancelled",
        }
    }

    /// Parse from an Elixir atom name.
    pub fn from_atom_name(name: &str) -> Option<Self> {
        match name {
            "pending" => Some(SignalStatus::Pending),
            "active" => Some(SignalStatus::Active),
            "completed" => Some(SignalStatus::Completed),
            "failed" => Some(SignalStatus::Failed),
            "cancelled" => Some(SignalStatus::Cancelled),
            _ => None,
        }
    }

    /// All variants as atom names.
    pub fn all_variants() -> Vec<&'static str> {
        vec![
            "pending",
            "active",
            "completed",
            "failed",
            "cancelled",
        ]
    }

    /// Encode as Elixir atom term.
    pub fn encode_term<'a>(&self, env: Env<'a>) -> Term<'a> {
        let atom = Atom::from_bytes(env, self.to_atom_name().as_bytes())
            .unwrap_or_else(|_| panic!("failed to create atom for {:?}", self));
        atom.encode(env)
    }
}

/// LLM provider enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LlmProvider {
    OpenAi,
    Anthropic,
    TogetherAi,
    Mira,
}

impl LlmProvider {
    pub fn to_atom_name(&self) -> &'static str {
        match self {
            LlmProvider::OpenAi => "open_ai",
            LlmProvider::Anthropic => "anthropic",
            LlmProvider::TogetherAi => "together_ai",
            LlmProvider::Mira => "mira",
        }
    }

    pub fn from_atom_name(name: &str) -> Option<Self> {
        match name {
            "open_ai" | "openai" => Some(LlmProvider::OpenAi),
            "anthropic" => Some(LlmProvider::Anthropic),
            "together_ai" | "togetherai" => Some(LlmProvider::TogetherAi),
            "mira" => Some(LlmProvider::Mira),
            _ => None,
        }
    }
}

/// Prism execution result status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PrismResult {
    Ok,
    Error,
    Timeout,
    Skipped,
}

impl PrismResult {
    pub fn to_atom_name(&self) -> &'static str {
        match self {
            PrismResult::Ok => "ok",
            PrismResult::Error => "error",
            PrismResult::Timeout => "timeout",
            PrismResult::Skipped => "skipped",
        }
    }

    pub fn from_atom_name(name: &str) -> Option<Self> {
        match name {
            "ok" => Some(PrismResult::Ok),
            "error" => Some(PrismResult::Error),
            "timeout" => Some(PrismResult::Timeout),
            "skipped" => Some(PrismResult::Skipped),
            _ => None,
        }
    }
}

/// NIF: Convert an Elixir atom to a string (for enum handling).
#[rustler::nif]
pub fn atom_to_string(atom: Atom) -> NifResult<String> {
    let env = atom.to_term(rustler::Env::new().unwrap_or_else(|| unsafe { std::mem::zeroed() })).get_env();
    atom.to_term(env)
        .atom_to_string()
        .map_err(|_| rustler::Error::RaiseAtom("atom_to_string_failed"))
}

/// NIF: Convert a string to an Elixir atom.
#[rustler::nif]
pub fn string_to_atom(name: String) -> NifResult<Atom> {
    let env = rustler::Env::new().unwrap_or_else(|| unsafe { std::mem::zeroed() });
    Atom::from_bytes(env, name.as_bytes())
        .map_err(|_| rustler::Error::RaiseTerm(Box::new(format!("cannot_create_atom: {}", name))))
}

/// NIF: Get all valid variants for a known enum type.
/// Returns `{:ok, [atom]}` or `{:error, :unknown_enum}`.
#[rustler::nif]
pub fn enum_variants(enum_type: String) -> NifResult<Term> {
    let env = rustler::Env::new().unwrap_or_else(|| unsafe { std::mem::zeroed() });

    let variants: Vec<&str> = match enum_type.as_str() {
        "signal_status" => SignalStatus::all_variants(),
        _ => {
            let error_atom = Atom::from_bytes(env, b"error").unwrap();
            let unknown = Atom::from_bytes(env, b"unknown_enum").unwrap();
            return Ok((error_atom, unknown).encode(env));
        }
    };

    let atoms: Vec<Term> = variants
        .iter()
        .map(|v| {
            Atom::from_bytes(env, v.as_bytes())
                .unwrap()
                .to_term(env)
        })
        .collect();

    let ok_atom = Atom::from_bytes(env, b"ok").unwrap();
    Ok((ok_atom, atoms).encode(env))
}

/// NIF: Validate that an atom is a valid variant of a known enum type.
/// Returns `{:ok, true}` or `{:ok, false}`.
#[rustler::nif]
pub fn validate_enum_variant(enum_type: String, variant: String) -> NifResult<Term> {
    let env = rustler::Env::new().unwrap_or_else(|| unsafe { std::mem::zeroed() });

    let valid = match enum_type.as_str() {
        "signal_status" => SignalStatus::from_atom_name(&variant).is_some(),
        "llm_provider" => LlmProvider::from_atom_name(&variant).is_some(),
        "prism_result" => PrismResult::from_atom_name(&variant).is_some(),
        _ => false,
    };

    let ok_atom = Atom::from_bytes(env, b"ok").unwrap();
    Ok((ok_atom, valid).encode(env))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_enum_value_from_str() {
        let v: EnumValue = ":active".parse().unwrap();
        assert_eq!(v.variant, "active");
    }

    #[test]
    fn test_signal_status_roundtrip() {
        for name in SignalStatus::all_variants() {
            let status = SignalStatus::from_atom_name(name).unwrap();
            assert_eq!(status.to_atom_name(), name);
        }
    }

    #[test]
    fn test_llm_provider() {
        assert_eq!(
            LlmProvider::from_atom_name("anthropic"),
            Some(LlmProvider::Anthropic)
        );
        assert_eq!(LlmProvider::Anthropic.to_atom_name(), "anthropic");
    }

    #[test]
    fn test_unknown_variant() {
        assert_eq!(SignalStatus::from_atom_name("unknown"), None);
    }

    #[test]
    fn test_enum_value_display() {
        let v = EnumValue::new("hello");
        assert_eq!(format!("{}", v), ":hello");
    }
}
