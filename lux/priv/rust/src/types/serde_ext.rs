//! # Serde Integration
//!
//! Provides JSON serialization/deserialization bridge between Elixir terms
//! and Rust types using a hand-rolled JSON encoder/decoder (no external deps).
//! Also provides a Serde-compatible API surface for future integration.

use rustler::{Atom, Decoder, Encoder, Env, NifResult, Term};
use std::collections::HashMap;

use super::container::Container;
use super::primitive::Primitive;

/// JSON value representation (no external serde dependency).
#[derive(Debug, Clone, PartialEq)]
pub enum JsonValue {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<JsonValue>),
    Object(Vec<(String, JsonValue)>),
}

impl JsonValue {
    /// Parse a JSON string into a JsonValue tree.
    pub fn parse(json: &str) -> Result<JsonValue, String> {
        let mut parser = JsonParser::new(json);
        parser.parse_value()
    }

    /// Serialize a JsonValue to a JSON string.
    pub fn to_json_string(&self) -> String {
        match self {
            JsonValue::Null => "null".to_string(),
            JsonValue::Bool(b) => b.to_string(),
            JsonValue::Number(n) => {
                if n.fract() == 0.0 {
                    format!("{}", *n as i64)
                } else {
                    format!("{}", n)
                }
            }
            JsonValue::String(s) => format!("\"{}\"", escape_json(s)),
            JsonValue::Array(items) => {
                let parts: Vec<String> = items.iter().map(|v| v.to_json_string()).collect();
                format!("[{}]", parts.join(","))
            }
            JsonValue::Object(pairs) => {
                let parts: Vec<String> = pairs
                    .iter()
                    .map(|(k, v)| format!("\"{}\":{}", escape_json(k), v.to_json_string()))
                    .collect();
                format!("{{{}}}", parts.join(","))
            }
        }
    }

    /// Convert from an Elixir term.
    pub fn from_term(term: Term) -> NifResult<JsonValue> {
        let container = Container::from_term(term)?;
        container_to_json(&container)
    }

    /// Convert to an Elixir term.
    pub fn to_term<'a>(&self, env: Env<'a>) -> Term<'a> {
        json_to_term_value(self, env)
    }

    /// Get the type name for introspection.
    pub fn type_name(&self) -> &'static str {
        match self {
            JsonValue::Null => "null",
            JsonValue::Bool(_) => "boolean",
            JsonValue::Number(_) => "number",
            JsonValue::String(_) => "string",
            JsonValue::Array(_) => "array",
            JsonValue::Object(_) => "object",
        }
    }
}

fn container_to_json(container: &Container) -> NifResult<JsonValue> {
    match container {
        Container::Primitive(p) => match p {
            Primitive::Nil => Ok(JsonValue::Null),
            Primitive::Boolean(b) => Ok(JsonValue::Bool(*b)),
            Primitive::Integer(i) => Ok(JsonValue::Number(*i as f64)),
            Primitive::Float(f) => Ok(JsonValue::Number(*f)),
            Primitive::String(s) => Ok(JsonValue::String(s.clone())),
            Primitive::Atom(a) => {
                // Special atoms
                match a.as_str() {
                    "true" => Ok(JsonValue::Bool(true)),
                    "false" => Ok(JsonValue::Bool(false)),
                    "nil" => Ok(JsonValue::Null),
                    _ => Ok(JsonValue::String(format!(":{}", a))),
                }
            }
        },
        Container::List(items) => {
            let json_items: Vec<JsonValue> = items
                .iter()
                .map(container_to_json)
                .collect::<NifResult<Vec<_>>>()?;
            Ok(JsonValue::Array(json_items))
        }
        Container::Map(pairs) => {
            let json_pairs: Vec<(String, JsonValue)> = pairs
                .iter()
                .map(|(k, v)| {
                    let key_str = match k {
                        Container::Primitive(Primitive::String(s)) => s.clone(),
                        Container::Primitive(Primitive::Atom(a)) => a.clone(),
                        other => format!("{:?}", other),
                    };
                    Ok((key_str, container_to_json(v)?))
                })
                .collect::<NifResult<Vec<_>>>()?;
            Ok(JsonValue::Object(json_pairs))
        }
        Container::Tuple(items) => {
            // Tuples become JSON arrays
            let json_items: Vec<JsonValue> = items
                .iter()
                .map(container_to_json)
                .collect::<NifResult<Vec<_>>>()?;
            Ok(JsonValue::Array(json_items))
        }
    }
}

fn json_to_term_value<'a>(json: &JsonValue, env: Env<'a>) -> Term<'a> {
    match json {
        JsonValue::Null => Atom::from_bytes(env, b"nil")
            .unwrap()
            .encode(env),
        JsonValue::Bool(b) => b.encode(env),
        JsonValue::Number(n) => {
            if n.fract() == 0.0 && *n >= i64::MIN as f64 && *n <= i64::MAX as f64 {
                (*n as i64).encode(env)
            } else {
                n.encode(env)
            }
        }
        JsonValue::String(s) => s.encode(env),
        JsonValue::Array(items) => {
            let terms: Vec<Term> = items.iter().map(|v| json_to_term_value(v, env)).collect();
            terms.encode(env)
        }
        JsonValue::Object(pairs) => {
            let mut map = rustler::types::map::MapTerm::new(env);
            for (k, v) in pairs {
                map = map
                    .put(k.encode(env), json_to_term_value(v, env))
                    .unwrap_or(map);
            }
            map.encode(env)
        }
    }
}

/// Simple recursive descent JSON parser.
struct JsonParser<'a> {
    input: &'a str,
    pos: usize,
}

impl<'a> JsonParser<'a> {
    fn new(input: &'a str) -> Self {
        JsonParser { input, pos: 0 }
    }

    fn skip_whitespace(&mut self) {
        while self.pos < self.input.len() {
            match self.input.as_bytes()[self.pos] {
                b' ' | b'\t' | b'\n' | b'\r' => self.pos += 1,
                _ => break,
            }
        }
    }

    fn peek(&mut self) -> Option<u8> {
        self.skip_whitespace();
        self.input.as_bytes().get(self.pos).copied()
    }

    fn consume(&mut self, expected: u8) -> Result<(), String> {
        self.skip_whitespace();
        if self.input.as_bytes().get(self.pos) == Some(&expected) {
            self.pos += 1;
            Ok(())
        } else {
            Err(format!(
                "expected '{}' at position {}",
                expected as char, self.pos
            ))
        }
    }

    fn parse_value(&mut self) -> Result<JsonValue, String> {
        self.skip_whitespace();
        match self.peek() {
            Some(b'{') => self.parse_object(),
            Some(b'[') => self.parse_array(),
            Some(b'"') => self.parse_string(),
            Some(b't') | Some(b'f') => self.parse_bool(),
            Some(b'n') => self.parse_null(),
            Some(b'-') | Some(c) if c.is_ascii_digit() => self.parse_number(),
            Some(c) => Err(format!("unexpected character '{}' at position {}", c as char, self.pos)),
            None => Err("unexpected end of input".to_string()),
        }
    }

    fn parse_object(&mut self) -> Result<JsonValue, String> {
        self.consume(b'{')?;
        let mut pairs = Vec::new();

        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(JsonValue::Object(pairs));
        }

        loop {
            let key = self.parse_string_inner()?;
            self.consume(b':')?;
            let value = self.parse_value()?;
            pairs.push((key, value));

            self.skip_whitespace();
            match self.peek() {
                Some(b',') => {
                    self.pos += 1;
                }
                Some(b'}') => {
                    self.pos += 1;
                    break;
                }
                _ => return Err(format!("expected ',' or '}}' at position {}", self.pos)),
            }
        }

        Ok(JsonValue::Object(pairs))
    }

    fn parse_array(&mut self) -> Result<JsonValue, String> {
        self.consume(b'[')?;
        let mut items = Vec::new();

        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(JsonValue::Array(items));
        }

        loop {
            items.push(self.parse_value()?);

            self.skip_whitespace();
            match self.peek() {
                Some(b',') => {
                    self.pos += 1;
                }
                Some(b']') => {
                    self.pos += 1;
                    break;
                }
                _ => return Err(format!("expected ',' or ']' at position {}", self.pos)),
            }
        }

        Ok(JsonValue::Array(items))
    }

    fn parse_string(&mut self) -> Result<JsonValue, String> {
        Ok(JsonValue::String(self.parse_string_inner()?))
    }

    fn parse_string_inner(&mut self) -> Result<String, String> {
        self.consume(b'"')?;
        let mut result = String::new();
        let bytes = self.input.as_bytes();

        while self.pos < bytes.len() {
            match bytes[self.pos] {
                b'"' => {
                    self.pos += 1;
                    return Ok(result);
                }
                b'\\' => {
                    self.pos += 1;
                    if self.pos >= bytes.len() {
                        return Err("unexpected end in string escape".to_string());
                    }
                    match bytes[self.pos] {
                        b'"' => result.push('"'),
                        b'\\' => result.push('\\'),
                        b'/' => result.push('/'),
                        b'n' => result.push('\n'),
                        b'r' => result.push('\r'),
                        b't' => result.push('\t'),
                        b'u' => {
                            // Parse 4 hex digits
                            self.pos += 1;
                            if self.pos + 4 > bytes.len() {
                                return Err("invalid unicode escape".to_string());
                            }
                            let hex: String = self.input[self.pos..self.pos + 4].to_string();
                            let code_point = u32::from_str_radix(&hex, 16)
                                .map_err(|e| format!("invalid unicode escape: {}", e))?;
                            if let Some(c) = char::from_u32(code_point) {
                                result.push(c);
                            }
                            self.pos += 3; // +1 at loop end
                        }
                        b => result.push(b as char),
                    }
                    self.pos += 1;
                }
                b => {
                    result.push(b as char);
                    self.pos += 1;
                }
            }
        }

        Err("unterminated string".to_string())
    }

    fn parse_number(&mut self) -> Result<JsonValue, String> {
        let start = self.pos;
        let bytes = self.input.as_bytes();

        // Optional minus
        if self.pos < bytes.len() && bytes[self.pos] == b'-' {
            self.pos += 1;
        }

        // Integer part
        while self.pos < bytes.len() && bytes[self.pos].is_ascii_digit() {
            self.pos += 1;
        }

        // Fractional part
        let mut is_float = false;
        if self.pos < bytes.len() && bytes[self.pos] == b'.' {
            is_float = true;
            self.pos += 1;
            while self.pos < bytes.len() && bytes[self.pos].is_ascii_digit() {
                self.pos += 1;
            }
        }

        // Exponent
        if self.pos < bytes.len() && (bytes[self.pos] == b'e' || bytes[self.pos] == b'E') {
            is_float = true;
            self.pos += 1;
            if self.pos < bytes.len() && (bytes[self.pos] == b'+' || bytes[self.pos] == b'-') {
                self.pos += 1;
            }
            while self.pos < bytes.len() && bytes[self.pos].is_ascii_digit() {
                self.pos += 1;
            }
        }

        let num_str = &self.input[start..self.pos];
        if is_float {
            let n: f64 = num_str
                .parse()
                .map_err(|e| format!("invalid float '{}': {}", num_str, e))?;
            Ok(JsonValue::Number(n))
        } else {
            let n: i64 = num_str
                .parse()
                .map_err(|e| format!("invalid integer '{}': {}", num_str, e))?;
            Ok(JsonValue::Number(n as f64))
        }
    }

    fn parse_bool(&mut self) -> Result<JsonValue, String> {
        let remaining = &self.input[self.pos..];
        if remaining.starts_with("true") {
            self.pos += 4;
            Ok(JsonValue::Bool(true))
        } else if remaining.starts_with("false") {
            self.pos += 5;
            Ok(JsonValue::Bool(false))
        } else {
            Err(format!("invalid boolean at position {}", self.pos))
        }
    }

    fn parse_null(&mut self) -> Result<JsonValue, String> {
        let remaining = &self.input[self.pos..];
        if remaining.starts_with("null") {
            self.pos += 4;
            Ok(JsonValue::Null)
        } else {
            Err(format!("expected 'null' at position {}", self.pos))
        }
    }
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

/// NIF: Parse a JSON string into an Elixir term with full parsing.
#[rustler::nif]
pub fn json_decode(json: String) -> NifResult<Term> {
    let env = rustler::Env::new().unwrap_or_else(|| unsafe { std::mem::zeroed() });
    let value = JsonValue::parse(&json).map_err(|e| {
        rustler::Error::RaiseTerm(Box::new(format!("json_parse_error: {}", e)))
    })?;
    Ok(value.to_term(env))
}

/// NIF: Encode an Elixir term into a JSON string with full serialization.
#[rustler::nif]
pub fn json_encode(term: Term) -> NifResult<String> {
    let value = JsonValue::from_term(term)?;
    Ok(value.to_json_string())
}

/// NIF: Pretty-print a JSON string with indentation.
#[rustler::nif]
pub fn json_pretty(json: String) -> NifResult<String> {
    let value = JsonValue::parse(&json).map_err(|e| {
        rustler::Error::RaiseTerm(Box::new(format!("json_parse_error: {}", e)))
    })?;
    Ok(pretty_print(&value, 0))
}

fn pretty_print(value: &JsonValue, indent: usize) -> String {
    let indent_str = "  ".repeat(indent);
    let inner_indent = "  ".repeat(indent + 1);

    match value {
        JsonValue::Null => "null".to_string(),
        JsonValue::Bool(b) => b.to_string(),
        JsonValue::Number(n) => {
            if n.fract() == 0.0 {
                format!("{}", *n as i64)
            } else {
                format!("{}", n)
            }
        }
        JsonValue::String(s) => format!("\"{}\"", escape_json(s)),
        JsonValue::Array(items) => {
            if items.is_empty() {
                "[]".to_string()
            } else {
                let parts: Vec<String> = items
                    .iter()
                    .map(|v| format!("{}{}", inner_indent, pretty_print(v, indent + 1)))
                    .collect();
                format!("[\n{}\n{}]", parts.join(",\n"), indent_str)
            }
        }
        JsonValue::Object(pairs) => {
            if pairs.is_empty() {
                "{}".to_string()
            } else {
                let parts: Vec<String> = pairs
                    .iter()
                    .map(|(k, v)| {
                        format!(
                            "{}\"{}\": {}",
                            inner_indent,
                            escape_json(k),
                            pretty_print(v, indent + 1)
                        )
                    })
                    .collect();
                format!("{{\n{}\n{}}}", parts.join(",\n"), indent_str)
            }
        }
    }
}

/// NIF: Get the JSON type of a value at a given path.
#[rustler::nif]
pub fn json_type_at(json: String, path: Vec<String>) -> NifResult<String> {
    let mut value = JsonValue::parse(&json).map_err(|e| {
        rustler::Error::RaiseTerm(Box::new(format!("json_parse_error: {}", e)))
    })?;

    for key in &path {
        value = match &value {
            JsonValue::Object(pairs) => pairs
                .iter()
                .find(|(k, _)| k == key)
                .map(|(_, v)| v.clone())
                .ok_or_else(|| {
                    rustler::Error::RaiseTerm(Box::new(format!("key_not_found: {}", key)))
                })?,
            JsonValue::Array(items) => {
                let idx: usize = key.parse().map_err(|_| {
                    rustler::Error::RaiseTerm(Box::new(format!("invalid_index: {}", key)))
                })?;
                items
                    .get(idx)
                    .cloned()
                    .ok_or_else(|| {
                        rustler::Error::RaiseTerm(Box::new(format!("index_out_of_bounds: {}", idx)))
                    })?
            }
            other => {
                return Err(rustler::Error::RaiseTerm(Box::new(format!(
                    "cannot_navigate_into: {}",
                    other.type_name()
                ))));
            }
        };
    }

    Ok(value.type_name().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_object() {
        let json = r#"{"name":"Lux","version":1}"#;
        let value = JsonValue::parse(json).unwrap();
        assert_eq!(
            value,
            JsonValue::Object(vec![
                ("name".to_string(), JsonValue::String("Lux".to_string())),
                ("version".to_string(), JsonValue::Number(1.0)),
            ])
        );
    }

    #[test]
    fn test_parse_array() {
        let json = r#"[1,2,3]"#;
        let value = JsonValue::parse(json).unwrap();
        assert_eq!(
            value,
            JsonValue::Array(vec![
                JsonValue::Number(1.0),
                JsonValue::Number(2.0),
                JsonValue::Number(3.0),
            ])
        );
    }

    #[test]
    fn test_parse_nested() {
        let json = r#"{"a":{"b":[true,null]}}"#;
        let value = JsonValue::parse(json).unwrap();
        match value {
            JsonValue::Object(pairs) => {
                assert_eq!(pairs.len(), 1);
            }
            _ => panic!("expected object"),
        }
    }

    #[test]
    fn test_roundtrip() {
        let json = r#"{"key":"value","num":42,"arr":[1,2,3]}"#;
        let value = JsonValue::parse(json).unwrap();
        let output = value.to_json_string();
        let reparsed = JsonValue::parse(&output).unwrap();
        assert_eq!(value, reparsed);
    }

    #[test]
    fn test_parse_bool_null() {
        let json = r#"[true,false,null]"#;
        let value = JsonValue::parse(json).unwrap();
        assert_eq!(
            value,
            JsonValue::Array(vec![
                JsonValue::Bool(true),
                JsonValue::Bool(false),
                JsonValue::Null,
            ])
        );
    }

    #[test]
    fn test_parse_string_escapes() {
        let json = r#"{"msg":"hello\nworld"}"#;
        let value = JsonValue::parse(json).unwrap();
        match value {
            JsonValue::Object(pairs) => {
                assert_eq!(pairs[0].1, JsonValue::String("hello\nworld".to_string()));
            }
            _ => panic!("expected object"),
        }
    }

    #[test]
    fn test_pretty_print() {
        let json = r#"{"a":1}"#;
        let value = JsonValue::parse(json).unwrap();
        let pretty = pretty_print(&value, 0);
        assert!(pretty.contains("\n"));
    }
}
