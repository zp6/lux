//! # Custom Type Definition Framework
//!
//! Provides a framework for defining and converting custom types between
//! Elixir structs and Rust structs, analogous to Elixir's `defstruct`.

use rustler::{Atom, Decoder, Encoder, Env, NifResult, Term};
use std::collections::HashMap;

use super::container::Container;
use super::primitive::Primitive;

/// A field definition in a custom type (analogous to `defstruct` field).
#[derive(Debug, Clone, PartialEq)]
pub struct FieldDef {
    pub name: String,
    pub type_name: String,
    pub default: Option<Primitive>,
}

/// A custom type schema definition (analogous to `defstruct`).
#[derive(Debug, Clone, PartialEq)]
pub struct CustomTypeDef {
    pub module: String,
    pub fields: Vec<FieldDef>,
}

impl CustomTypeDef {
    /// Create a new custom type definition.
    pub fn new(module: &str) -> Self {
        CustomTypeDef {
            module: module.to_string(),
            fields: Vec::new(),
        }
    }

    /// Add a field to the type definition.
    pub fn field(mut self, name: &str, type_name: &str) -> Self {
        self.fields.push(FieldDef {
            name: name.to_string(),
            type_name: type_name.to_string(),
            default: None,
        });
        self
    }

    /// Add a field with a default value.
    pub fn field_with_default(mut self, name: &str, type_name: &str, default: Primitive) -> Self {
        self.fields.push(FieldDef {
            name: name.to_string(),
            type_name: type_name.to_string(),
            default: Some(default),
        });
        self
    }

    /// Get a field definition by name.
    pub fn get_field(&self, name: &str) -> Option<&FieldDef> {
        self.fields.iter().find(|f| f.name == name)
    }

    /// Encode this type definition as an Elixir map for introspection.
    pub fn encode_def<'a>(&self, env: Env<'a>) -> Term<'a> {
        let mut map = rustler::types::map::MapTerm::new(env);
        map = map
            .put("__module__".encode(env), self.module.encode(env))
            .unwrap_or(map);

        let field_maps: Vec<Term> = self
            .fields
            .iter()
            .map(|f| {
                let mut fm = rustler::types::map::MapTerm::new(env);
                fm = fm
                    .put("name".encode(env), f.name.encode(env))
                    .unwrap_or(fm);
                fm = fm
                    .put("type".encode(env), f.type_name.encode(env))
                    .unwrap_or(fm);
                fm = fm
                    .put(
                        "has_default".encode(env),
                        f.default.is_some().encode(env),
                    )
                    .unwrap_or(fm);
                if let Some(ref default) = f.default {
                    fm = fm
                        .put("default".encode(env), default.encode_term(env))
                        .unwrap_or(fm);
                }
                fm.encode(env)
            })
            .collect();

        map = map
            .put("__fields__".encode(env), field_maps.encode(env))
            .unwrap_or(map);

        map.encode(env)
    }
}

/// A registry of custom type definitions.
#[derive(Debug, Clone, Default)]
pub struct TypeRegistry {
    definitions: HashMap<String, CustomTypeDef>,
}

impl TypeRegistry {
    /// Create a new empty registry.
    pub fn new() -> Self {
        TypeRegistry {
            definitions: HashMap::new(),
        }
    }

    /// Register a custom type definition.
    pub fn register(&mut self, def: CustomTypeDef) {
        self.definitions.insert(def.module.clone(), def);
    }

    /// Look up a type definition by module name.
    pub fn get(&self, module: &str) -> Option<&CustomTypeDef> {
        self.definitions.get(module)
    }

    /// List all registered module names.
    pub fn module_names(&self) -> Vec<String> {
        self.definitions.keys().cloned().collect()
    }

    /// Encode the entire registry as an Elixir term.
    pub fn encode_registry<'a>(&self, env: Env<'a>) -> Term<'a> {
        let entries: Vec<Term> = self
            .definitions
            .values()
            .map(|def| def.encode_def(env))
            .collect();
        entries.encode(env)
    }
}

/// Convert an Elixir struct-like map into a generic field map.
/// Expects `__struct__` key to identify the type.
pub fn struct_to_map(term: Term) -> NifResult<(String, HashMap<String, Container>)> {
    let container = Container::from_term(term)?;

    match &container {
        Container::Map(pairs) => {
            let mut module_name = String::new();
            let mut fields = HashMap::new();

            for (k, v) in pairs {
                if let Container::Primitive(Primitive::Atom(key)) = k {
                    if key == "__struct__" {
                        if let Container::Primitive(Primitive::Atom(mod_name)) = v {
                            module_name = mod_name.clone();
                        } else if let Container::Primitive(Primitive::String(mod_name)) = v {
                            module_name = mod_name.clone();
                        }
                        continue;
                    }
                }
                // Use a string representation of the key
                let key_str = container_to_string(k);
                fields.insert(key_str, v.clone());
            }

            if module_name.is_empty() {
                return Err(rustler::Error::RaiseAtom("missing_struct_key"));
            }

            Ok((module_name, fields))
        }
        _ => Err(rustler::Error::RaiseAtom("not_a_map")),
    }
}

fn container_to_string(c: &Container) -> String {
    match c {
        Container::Primitive(Primitive::String(s)) => s.clone(),
        Container::Primitive(Primitive::Atom(a)) => a.clone(),
        Container::Primitive(p) => format!("{}", p),
        _ => format!("{:?}", c),
    }
}

/// Build an Elixir struct-like map from a module name and field values.
pub fn map_to_struct<'a>(
    env: Env<'a>,
    module: &str,
    fields: &HashMap<String, Container>,
) -> NifResult<Term<'a>> {
    let mut map = rustler::types::map::MapTerm::new(env);

    // Add __struct__ key
    let struct_atom = Atom::from_bytes(env, b"Elixir.Elixir").unwrap_or_else(|_| {
        // Fallback: encode module name as string
        Atom::from_bytes(env, module.as_bytes()).unwrap()
    });

    // Encode module name as atom (e.g., "Elixir.Lux.MyStruct")
    let module_atom = Atom::from_bytes(env, module.as_bytes()).unwrap_or_else(|_| struct_atom);
    map = map
        .put("__struct__".encode(env), module_atom.encode(env))
        .unwrap_or(map);

    // Add fields
    for (key, value) in fields {
        let key_term = key.encode(env);
        let val_term = value.encode_term(env);
        map = map.put(key_term, val_term).unwrap_or(map);
    }

    Ok(map.encode(env))
}

// Global registry stored as a NIF resource (lazy static)
use std::sync::Mutex;

lazy_static::lazy_static! {
    static ref GLOBAL_REGISTRY: Mutex<TypeRegistry> = Mutex::new(TypeRegistry::new());
}

/// NIF: Register a custom type definition from Elixir.
/// Takes `%{module: "Module.Name", fields: [%{name: "field", type: "string", default: value}]}`
#[rustler::nif]
pub fn register_type(def_term: Term) -> NifResult<Term> {
    let env = def_term.get_env();

    let def_map: HashMap<String, Term> = def_term.decode()?;
    let module: String = def_map
        .get("module")
        .ok_or(rustler::Error::RaiseAtom("missing_module"))?
        .decode()?;

    let field_terms: Vec<HashMap<String, Term>> = def_map
        .get("fields")
        .ok_or(rustler::Error::RaiseAtom("missing_fields"))?
        .decode()?;

    let mut type_def = CustomTypeDef::new(&module);
    for ft in &field_terms {
        let name: String = ft
            .get("name")
            .ok_or(rustler::Error::RaiseAtom("missing_field_name"))?
            .decode()?;
        let type_name: String = ft
            .get("type")
            .ok_or(rustler::Error::RaiseAtom("missing_field_type"))?
            .decode()?;

        if let Some(default_term) = ft.get("default") {
            let default = Primitive::from_term(*default_term)?;
            type_def = type_def.field_with_default(&name, &type_name, default);
        } else {
            type_def = type_def.field(&name, &type_name);
        }
    }

    let mut registry = GLOBAL_REGISTRY.lock().unwrap();
    registry.register(type_def);

    let ok_atom = Atom::from_bytes(env, b"ok").unwrap();
    Ok(ok_atom.encode(env))
}

/// NIF: Look up a registered type definition by module name.
/// Returns `{:ok, definition_map}` or `{:error, :not_found}`.
#[rustler::nif]
pub fn get_type_definition(module: String) -> NifResult<Term> {
    let env = rustler::Env::new().unwrap_or_else(|| unsafe { std::mem::zeroed() });
    let registry = GLOBAL_REGISTRY.lock().unwrap();

    match registry.get(&module) {
        Some(def) => {
            let ok_atom = Atom::from_bytes(env, b"ok").unwrap();
            Ok((ok_atom, def.encode_def(env)).encode(env))
        }
        None => {
            let error_atom = Atom::from_bytes(env, b"error").unwrap();
            let not_found = Atom::from_bytes(env, b"not_found").unwrap();
            Ok((error_atom, not_found).encode(env))
        }
    }
}

/// NIF: List all registered type module names.
#[rustler::nif]
pub fn list_registered_types() -> NifResult<Term> {
    let env = rustler::Env::new().unwrap_or_else(|| unsafe { std::mem::zeroed() });
    let registry = GLOBAL_REGISTRY.lock().unwrap();
    let names = registry.module_names();
    Ok(names.encode(env))
}

/// NIF: Convert an Elixir struct (map with __struct__) to a flat field map.
/// Returns `{:ok, %{module: module_name, fields: %{field_name => value}}}`.
#[rustler::nif]
pub fn decode_struct(term: Term) -> NifResult<Term> {
    let env = term.get_env();
    let (module, fields) = struct_to_map(term)?;

    let mut result = rustler::types::map::MapTerm::new(env);
    result = result
        .put("module".encode(env), module.encode(env))
        .unwrap_or(result);

    let field_map = rustler::types::map::MapTerm::new(env);
    let mut built_map = field_map;
    for (key, value) in &fields {
        built_map = built_map
            .put(key.encode(env), value.encode_term(env))
            .unwrap_or(built_map);
    }

    result = result
        .put("fields".encode(env), built_map.encode(env))
        .unwrap_or(result);

    let ok_atom = Atom::from_bytes(env, b"ok").unwrap();
    Ok((ok_atom, result.encode(env)).encode(env))
}

/// NIF: Build an Elixir struct-like map from a module name and field map.
/// Takes `%{module: "Module.Name", fields: %{field => value}}`.
#[rustler::nif]
pub fn encode_struct(term: Term) -> NifResult<Term> {
    let env = term.get_env();
    let map: HashMap<String, Term> = term.decode()?;

    let module: String = map
        .get("module")
        .ok_or(rustler::Error::RaiseAtom("missing_module"))?
        .decode()?;

    let fields_term = map
        .get("fields")
        .ok_or(rustler::Error::RaiseAtom("missing_fields"))?;

    let field_map: HashMap<String, Term> = fields_term.decode()?;

    let container_fields: HashMap<String, Container> = field_map
        .into_iter()
        .map(|(k, v)| Ok((k, Container::from_term(v)?)))
        .collect::<NifResult<_>>()?;

    map_to_struct(env, &module, &container_fields)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_custom_type_builder() {
        let def = CustomTypeDef::new("Lux.User")
            .field("name", "string")
            .field("age", "integer")
            .field_with_default("active", "boolean", Primitive::Boolean(true));

        assert_eq!(def.module, "Lux.User");
        assert_eq!(def.fields.len(), 3);
        assert_eq!(
            def.get_field("name").map(|f| f.type_name.as_str()),
            Some("string")
        );
        assert_eq!(
            def.get_field("active").and_then(|f| f.default.as_ref()),
            Some(&Primitive::Boolean(true))
        );
    }

    #[test]
    fn test_registry() {
        let mut registry = TypeRegistry::new();
        let def = CustomTypeDef::new("Lux.User").field("name", "string");
        registry.register(def);

        assert!(registry.get("Lux.User").is_some());
        assert!(registry.get("Lux.Unknown").is_none());
        assert_eq!(registry.module_names(), vec!["Lux.User"]);
    }
}
