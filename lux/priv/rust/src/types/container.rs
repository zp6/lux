//! # Container Type Conversions
//!
//! Bidirectional conversion for Elixir containers (lists, maps, tuples)
//! and their Rust equivalents (Vec, HashMap, tuples).

use rustler::{Decoder, Encoder, Env, NifResult, Term};
use std::collections::HashMap;

use super::primitive::Primitive;

/// Represents a dynamic container value that can hold nested data.
#[derive(Debug, Clone, PartialEq)]
pub enum Container {
    List(Vec<Container>),
    Map(Vec<(Container, Container)>),
    Tuple(Vec<Container>),
    Primitive(Primitive),
}

impl Container {
    /// Recursively decode an Elixir term into a Container tree.
    pub fn from_term(term: Term) -> NifResult<Self> {
        // Try primitive first
        if let Ok(p) = Primitive::from_term(term) {
            return Ok(Container::Primitive(p));
        }

        // Try map
        if let Ok(map) = term.decode::<HashMap<Term, Term>>() {
            let pairs: Vec<(Container, Container)> = map
                .into_iter()
                .map(|(k, v)| Ok((Container::from_term(k)?, Container::from_term(v)?)))
                .collect::<NifResult<Vec<_>>>()?;
            return Ok(Container::Map(pairs));
        }

        // Try list
        if let Ok(list) = term.decode::<Vec<Term>>() {
            let items: Vec<Container> = list
                .into_iter()
                .map(Container::from_term)
                .collect::<NifResult<Vec<_>>>()?;
            return Ok(Container::List(items));
        }

        // Try tuple
        if term.is_tuple() {
            let len = tuple_length(term)?;
            let mut items = Vec::with_capacity(len);
            for i in 0..len {
                let elem = tuple_get_element(term, i)?;
                items.push(Container::from_term(elem)?);
            }
            return Ok(Container::Tuple(items));
        }

        Err(rustler::Error::RaiseAtom("cannot_decode_container"))
    }

    /// Encode this Container back into an Elixir term.
    pub fn encode_term<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Container::Primitive(p) => p.encode_term(env),
            Container::List(items) => {
                let encoded: Vec<Term> = items.iter().map(|c| c.encode_term(env)).collect();
                encoded.encode(env)
            }
            Container::Map(pairs) => {
                let mut map = rustler::types::map::MapTerm::new(env);
                for (k, v) in pairs {
                    map = map.put(k.encode_term(env), v.encode_term(env)).unwrap_or(map);
                }
                map.encode(env)
            }
            Container::Tuple(items) => {
                let encoded: Vec<Term> = items.iter().map(|c| c.encode_term(env)).collect();
                rustler::types::tuple::make_tuple(env, &encoded)
            }
        }
    }

    /// Returns the container type name for introspection.
    pub fn type_name(&self) -> &'static str {
        match self {
            Container::List(_) => "list",
            Container::Map(_) => "map",
            Container::Tuple(_) => "tuple",
            Container::Primitive(p) => p.type_name(),
        }
    }

    /// Returns the depth of nesting in this container.
    pub fn depth(&self) -> usize {
        match self {
            Container::Primitive(_) => 0,
            Container::List(items) => items.iter().map(|c| c.depth()).max().unwrap_or(0) + 1,
            Container::Map(pairs) => pairs
                .iter()
                .flat_map(|(k, v)| [k.depth(), v.depth()])
                .max()
                .unwrap_or(0)
                + 1,
            Container::Tuple(items) => items.iter().map(|c| c.depth()).max().unwrap_or(0) + 1,
        }
    }

    /// Count total elements (recursive).
    pub fn count(&self) -> usize {
        match self {
            Container::Primitive(_) => 1,
            Container::List(items) => items.iter().map(|c| c.count()).sum(),
            Container::Map(pairs) => pairs
                .iter()
                .flat_map(|(k, v)| [k.count(), v.count()])
                .sum(),
            Container::Tuple(items) => items.iter().map(|c| c.count()).sum(),
        }
    }

    /// Try to get this as a Vec of containers (if it's a list).
    pub fn as_list(&self) -> Option<&Vec<Container>> {
        match self {
            Container::List(items) => Some(items),
            _ => None,
        }
    }

    /// Try to get this as key-value pairs (if it's a map).
    pub fn as_map(&self) -> Option<&Vec<(Container, Container)>> {
        match self {
            Container::Map(pairs) => Some(pairs),
            _ => None,
        }
    }
}

/// Helper: get tuple length from a term.
fn tuple_length(term: Term) -> NifResult<usize> {
    let env = term.get_env();
    let tuple = rustler::types::tuple::get_tuple(term)?;
    Ok(tuple.len())
}

/// Helper: get tuple element at index.
fn tuple_get_element(term: Term, index: usize) -> NifResult<Term> {
    let tuple = rustler::types::tuple::get_tuple(term)?;
    tuple
        .get(index)
        .cloned()
        .ok_or(rustler::Error::RaiseAtom("tuple_index_out_of_bounds"))
}

/// NIF: Inspect a term's type structure, returning a descriptor map.
/// Returns `{:ok, %{type: type_name, depth: depth, count: count}}`.
#[rustler::nif]
pub fn inspect_container(term: Term) -> NifResult<Term> {
    let env = term.get_env();
    let container = Container::from_term(term)?;

    let mut map = rustler::types::map::MapTerm::new(env);
    map = map
        .put("type".encode(env), container.type_name().encode(env))
        .unwrap_or(map);
    map = map
        .put("depth".encode(env), container.depth().encode(env))
        .unwrap_or(map);
    map = map
        .put("count".encode(env), container.count().encode(env))
        .unwrap_or(map);

    let ok_atom = rustler::Atom::from_bytes(env, b"ok").unwrap();
    Ok((ok_atom, map.encode(env)).encode(env))
}

/// NIF: Round-trip a term through the Container system.
/// Useful for testing that complex nested types survive conversion.
#[rustler::nif]
pub fn container_echo(term: Term) -> NifResult<Term> {
    let env = term.get_env();
    let container = Container::from_term(term)?;
    Ok(container.encode_term(env))
}

/// NIF: Flatten a nested list/tuple into a flat list.
#[rustler::nif]
pub fn flatten_container(term: Term) -> NifResult<Term> {
    let env = term.get_env();
    let container = Container::from_term(term)?;
    let flat = flatten_recursive(&container);
    let encoded: Vec<Term> = flat.iter().map(|c| c.encode_term(env)).collect();
    Ok(encoded.encode(env))
}

fn flatten_recursive(container: &Container) -> Vec<Container> {
    match container {
        Container::Primitive(p) => vec![Container::Primitive(p.clone())],
        Container::List(items) => items.iter().flat_map(flatten_recursive).collect(),
        Container::Tuple(items) => items.iter().flat_map(flatten_recursive).collect(),
        Container::Map(pairs) => pairs
            .iter()
            .flat_map(|(k, v)| {
                let mut result = flatten_recursive(k);
                result.extend(flatten_recursive(v));
                result
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_primitive_container() {
        let c = Container::Primitive(Primitive::Integer(42));
        assert_eq!(c.type_name(), "integer");
        assert_eq!(c.depth(), 0);
        assert_eq!(c.count(), 1);
    }

    #[test]
    fn test_list_container() {
        let c = Container::List(vec![
            Container::Primitive(Primitive::Integer(1)),
            Container::Primitive(Primitive::Integer(2)),
        ]);
        assert_eq!(c.type_name(), "list");
        assert_eq!(c.depth(), 1);
        assert_eq!(c.count(), 2);
    }

    #[test]
    fn test_nested_depth() {
        let c = Container::List(vec![Container::List(vec![
            Container::Primitive(Primitive::Integer(1)),
        ])]);
        assert_eq!(c.depth(), 2);
    }

    #[test]
    fn test_as_list() {
        let items = vec![Container::Primitive(Primitive::Integer(1))];
        let c = Container::List(items);
        assert!(c.as_list().is_some());
        assert!(c.as_map().is_none());
    }
}
