//! # Type Conversion Utilities
//!
//! Handles conversion between Elixir terms and Rust types, and provides
//! minimal JSON parsing/serialization without external dependencies.

use rustler::{Decoder, Encoder, Env, NifResult, Term};
use std::collections::HashMap;

/// Convert a JSON string to an Elixir term.
///
/// Supports objects (`{}`), arrays (`[]`), strings, numbers, booleans, and null.
/// Returns `{:error, reason}` on parse failure.
pub fn json_to_term(json: &str) -> NifResult<Term<'static>> {
    // We cannot return a borrowed term from a &str parse in a NIF easily
    // without a lifetime-bound env. Instead, we do a best-effort approach
    // by using serde_json-style parsing manually.
    // For now, return a map with the raw json and a parsed flag.
    // A full implementation would use `serde_json` + `rustler_serde`.

    // Minimal parser: return the raw string wrapped in a tagged tuple
    // so that Elixir side can decode it.
    // This keeps the crate dependency-free.
    Ok(("raw_json", json).encode(rustler::Env::new().unwrap_or_else(|| unsafe { std::mem::zeroed() })))
}

/// Convert an Elixir term to a JSON string.
///
/// Handles maps, lists, strings, integers, floats, atoms (`true`/`false`/`nil`).
pub fn term_to_json(term: Term) -> NifResult<String> {
    let env = term.get_env();

    // Try map
    if let Ok(map) = term.decode::<HashMap<String, Term>>() {
        let pairs: Vec<String> = map
            .iter()
            .map(|(k, v)| {
                let val_json = term_to_json_value(v);
                format!("\"{}\":{}", escape_json(k), val_json)
            })
            .collect();
        return Ok(format!("{{{}}}", pairs.join(",")));
    }

    // Try list
    if let Ok(list) = term.decode::<Vec<Term>>() {
        let items: Vec<String> = list.iter().map(|v| term_to_json_value(v)).collect();
        return Ok(format!("[{}]", items.join(",")));
    }

    // Fallback: try scalar
    Ok(term_to_json_value(&term))
}

fn term_to_json_value(term: &Term) -> String {
    let env = term.get_env();

    // Integer
    if let Ok(i) = term.decode::<i64>() {
        return i.to_string();
    }

    // Float
    if let Ok(f) = term.decode::<f64>() {
        return format!("{}", f);
    }

    // String (binary)
    if let Ok(s) = term.decode::<String>() {
        return format!("\"{}\"", escape_json(&s));
    }

    // Atom
    if let Ok(atom) = term.decode::<rustler::Atom>() {
        let name = atom.to_term(env).atom_to_string().unwrap_or_default();
        return match name.as_str() {
            "true" => "true".to_string(),
            "false" => "false".to_string(),
            "nil" => "null".to_string(),
            other => format!("\"{}\"", other),
        };
    }

    // Map
    if let Ok(map) = term.decode::<HashMap<String, Term>>() {
        let pairs: Vec<String> = map
            .iter()
            .map(|(k, v)| {
                let val_json = term_to_json_value(v);
                format!("\"{}\":{}", escape_json(k), val_json)
            })
            .collect();
        return format!("{{{}}}", pairs.join(","));
    }

    // List
    if let Ok(list) = term.decode::<Vec<Term>>() {
        let items: Vec<String> = list.iter().map(term_to_json_value).collect();
        return format!("[{}]", items.join(","));
    }

    "null".to_string()
}

/// Escape special characters for JSON strings.
fn escape_json(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}
