//! Wrapper module to expose all NIF functions from the types sub-module.
//!
//! Rustler's `rustler::init!` macro needs all NIF functions at the top level,
//! so we re-export them here.

pub use types::primitive::{decode_primitive, encode_primitive};
pub use types::container::{inspect_container, container_echo, flatten_container};
pub use types::custom::{register_type, get_type_definition, list_registered_types, decode_struct, encode_struct};
pub use types::enum_conv::{atom_to_string, string_to_atom, enum_variants, validate_enum_variant};
pub use types::serde_ext::{json_decode, json_encode, json_pretty, json_type_at};
