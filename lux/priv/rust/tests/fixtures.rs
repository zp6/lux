//! # Test Fixtures and Helpers
//!
//! Shared test utilities, sample data, and helper functions for Rust NIF tests.

/// Sample JSON strings for parse/serialize round-trip testing.
pub mod json_samples {
    pub const SIMPLE_OBJECT: &str = r#"{"name":"Lux","version":1}"#;
    pub const NESTED_OBJECT: &str = r#"{"user":{"name":"Alice","age":30}}"#;
    pub const ARRAY: &str = r#"[1,2,3,4,5]"#;
    pub const MIXED: &str = r#"{"bool":true,"null":null,"num":42,"str":"hello"}"#;
    pub const EMPTY_OBJECT: &str = "{}";
    pub const EMPTY_ARRAY: &str = "[]";
}

/// Well-known SHA-256 test vectors (input → expected hex digest).
pub mod sha256_vectors {
    pub const EMPTY_INPUT: (&str, &str) = (
        "",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    );
    pub const HELLO: (&str, &str) = (
        "hello",
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
    );
    pub const ABC: (&str, &str) = (
        "abc",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
    pub const LONG_STRING: (&str, &str) = (
        "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    );
}

/// UUID v4 validation helpers.
pub mod uuid_helpers {
    /// Regex pattern for a valid UUID v4 string.
    pub const UUID_V4_PATTERN: &str =
        r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$";

    /// Check if a string matches the UUID v4 format (simple validation without regex crate).
    pub fn is_valid_uuid_v4(s: &str) -> bool {
        if s.len() != 36 {
            return false;
        }
        let chars: Vec<char> = s.chars().collect();

        // Check dashes at positions 8, 13, 18, 23
        if chars[8] != '-' || chars[13] != '-' || chars[18] != '-' || chars[23] != '-' {
            return false;
        }

        // Check hex digits at all other positions
        let hex_positions: Vec<usize> = (0..36)
            .filter(|&i| i != 8 && i != 13 && i != 18 && i != 23)
            .collect();
        for pos in hex_positions {
            if !chars[pos].is_ascii_hexdigit() {
                return false;
            }
        }

        // Version nibble at position 14 must be '4'
        if chars[14] != '4' {
            return false;
        }

        // Variant nibble at position 19 must be 8, 9, a, or b
        matches!(chars[19], '8' | '9' | 'a' | 'b')
    }
}

/// Arithmetic test cases: (a, b, expected_sum).
pub mod arithmetic_cases {
    pub const POSITIVE: (f64, f64, f64) = (1.0, 2.0, 3.0);
    pub const NEGATIVE: (f64, f64, f64) = (-1.0, -2.0, -3.0);
    pub const MIXED: (f64, f64, f64) = (-1.0, 3.0, 2.0);
    pub const ZERO: (f64, f64, f64) = (0.0, 0.0, 0.0);
    pub const FLOATS: (f64, f64, f64) = (1.5, 2.5, 4.0);
    pub const LARGE: (f64, f64, f64) = (1_000_000.0, 999_999.0, 1_999_999.0);
}

/// Helper to check if a hex string is valid (all lowercase hex chars).
pub fn is_valid_hex(s: &str) -> bool {
    s.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f'))
}

#[cfg(test)]
mod fixture_tests {
    use super::*;

    #[test]
    fn test_uuid_v4_validation_valid() {
        assert!(uuid_helpers::is_valid_uuid_v4(
            "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
        ));
    }

    #[test]
    fn test_uuid_v4_validation_invalid_version() {
        assert!(!uuid_helpers::is_valid_uuid_v4(
            "a1b2c3d4-e5f6-5a7b-8c9d-0e1f2a3b4c5d"
        ));
    }

    #[test]
    fn test_uuid_v4_validation_too_short() {
        assert!(!uuid_helpers::is_valid_uuid_v4("short"));
    }

    #[test]
    fn test_is_valid_hex() {
        assert!(is_valid_hex("abcdef0123456789"));
        assert!(!is_valid_hex("ABCDEF"));
        assert!(!is_valid_hex("xyz"));
    }
}
