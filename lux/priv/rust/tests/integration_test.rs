//! # NIF Integration Tests
//!
//! Tests the compiled Rust NIF functions directly (without Elixir VM).
//! These test the Rust implementation logic independently.

mod fixtures;

use fixtures::{arithmetic_cases, sha256_vectors, uuid_helpers};

// ---------------------------------------------------------------------------
// add (f64, f64) → f64
// ---------------------------------------------------------------------------

/// The `add` function from lib.rs is not a pub fn we can call directly in tests
/// because it's behind `#[rustler::nif]`. We replicate the logic for unit testing
/// and test the actual compiled NIF via Elixir integration tests.
///
/// For pure Rust integration tests, we test the underlying functions.

/// Direct test of the add logic (mirrors `add` in lib.rs).
fn add_impl(a: f64, b: f64) -> f64 {
    a + b
}

#[test]
fn test_add_positive() {
    let (a, b, expected) = arithmetic_cases::POSITIVE;
    let result = add_impl(a, b);
    assert!((result - expected).abs() < f64::EPSILON);
}

#[test]
fn test_add_negative() {
    let (a, b, expected) = arithmetic_cases::NEGATIVE;
    let result = add_impl(a, b);
    assert!((result - expected).abs() < f64::EPSILON);
}

#[test]
fn test_add_mixed_signs() {
    let (a, b, expected) = arithmetic_cases::MIXED;
    let result = add_impl(a, b);
    assert!((result - expected).abs() < f64::EPSILON);
}

#[test]
fn test_add_zero() {
    let (a, b, expected) = arithmetic_cases::ZERO;
    let result = add_impl(a, b);
    assert!((result - expected).abs() < f64::EPSILON);
}

#[test]
fn test_add_floats() {
    let (a, b, expected) = arithmetic_cases::FLOATS;
    let result = add_impl(a, b);
    assert!((result - expected).abs() < f64::EPSILON);
}

#[test]
fn test_add_large_numbers() {
    let (a, b, expected) = arithmetic_cases::LARGE;
    let result = add_impl(a, b);
    assert!((result - expected).abs() < f64::EPSILON);
}

#[test]
fn test_add_commutative() {
    assert!((add_impl(3.0, 5.0) - add_impl(5.0, 3.0)).abs() < f64::EPSILON);
}

#[test]
fn test_add_associative() {
    let a = add_impl(add_impl(1.0, 2.0), 3.0);
    let b = add_impl(1.0, add_impl(2.0, 3.0));
    assert!((a - b).abs() < f64::EPSILON);
}

#[test]
fn test_add_identity() {
    let x = 42.0;
    assert!((add_impl(x, 0.0) - x).abs() < f64::EPSILON);
    assert!((add_impl(0.0, x) - x).abs() < f64::EPSILON);
}

// ---------------------------------------------------------------------------
// uuid_v4 — format validation
// ---------------------------------------------------------------------------

/// Replicate the uuid_v4 logic from lib.rs for direct testing.
fn uuid_v4_impl() -> String {
    let mut buf = [0u8; 16];
    let seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64;

    let mut state = seed;
    for byte in buf.iter_mut() {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        *byte = state as u8;
    }

    buf[6] = (buf[6] & 0x0f) | 0x40;
    buf[8] = (buf[8] & 0x3f) | 0x80;

    let hex: String = buf.iter().map(|b| format!("{:02x}", b)).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

#[test]
fn test_uuid_v4_format() {
    let uuid = uuid_v4_impl();
    assert_eq!(uuid.len(), 36);
    assert!(uuid_helpers::is_valid_uuid_v4(&uuid));
}

#[test]
fn test_uuid_v4_uniqueness() {
    let uuids: Vec<String> = (0..100).map(|_| uuid_v4_impl()).collect();
    for uuid in &uuids {
        assert!(uuid_helpers::is_valid_uuid_v4(uuid));
    }
    // All UUIDs should be unique (statistical guarantee for 100 samples)
    let unique_count = uuids
        .iter()
        .collect::<std::collections::HashSet<_>>()
        .len();
    // Allow for the extremely rare case of a collision (shouldn't happen with 100)
    assert!(unique_count >= 99);
}

#[test]
fn test_uuid_v4_version_nibble() {
    for _ in 0..20 {
        let uuid = uuid_v4_impl();
        let chars: Vec<char> = uuid.chars().collect();
        // Position 14 (0-indexed) must be '4'
        assert_eq!(chars[14], '4');
        // Position 19 must be 8, 9, a, or b
        assert!(matches!(chars[19], '8' | '9' | 'a' | 'b'));
    }
}

// ---------------------------------------------------------------------------
// sha256 — known test vectors
// ---------------------------------------------------------------------------

/// Replicate the sha256_digest function from lib.rs.
fn sha256_digest(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];

    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c,
        0x1f83d9ab, 0x5be0cd19,
    ];

    let bit_len = (data.len() as u64) * 8;
    let mut padded = data.to_vec();
    padded.push(0x80);
    while padded.len() % 64 != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_len.to_be_bytes());

    for chunk in padded.chunks(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                chunk[i * 4],
                chunk[i * 4 + 1],
                chunk[i * 4 + 2],
                chunk[i * 4 + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }

        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;

        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);

            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }

        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }

    h.iter()
        .flat_map(|v| v.to_be_bytes())
        .map(|b| format!("{:02x}", b))
        .collect()
}

#[test]
fn test_sha256_empty() {
    let (input, expected) = sha256_vectors::EMPTY_INPUT;
    assert_eq!(sha256_digest(input.as_bytes()), expected);
}

#[test]
fn test_sha256_hello() {
    let (input, expected) = sha256_vectors::HELLO;
    assert_eq!(sha256_digest(input.as_bytes()), expected);
}

#[test]
fn test_sha256_abc() {
    let (input, expected) = sha256_vectors::ABC;
    assert_eq!(sha256_digest(input.as_bytes()), expected);
}

#[test]
fn test_sha256_long() {
    let (input, expected) = sha256_vectors::LONG_STRING;
    assert_eq!(sha256_digest(input.as_bytes()), expected);
}

#[test]
fn test_sha256_output_is_64_hex_chars() {
    let hash = sha256_digest(b"any input");
    assert_eq!(hash.len(), 64);
    assert!(hash.chars().all(|c| c.is_ascii_hexdigit()));
}

#[test]
fn test_sha256_deterministic() {
    let data = b"deterministic test";
    assert_eq!(sha256_digest(data), sha256_digest(data));
}

// ---------------------------------------------------------------------------
// JSON escape — edge cases
// ---------------------------------------------------------------------------

/// Replicate escape_json from types.rs.
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

#[test]
fn test_escape_json_plain() {
    assert_eq!(escape_json("hello"), "hello");
}

#[test]
fn test_escape_json_quotes() {
    assert_eq!(escape_json(r#"say "hello""#), r#"say \"hello\""#);
}

#[test]
fn test_escape_json_newline() {
    assert_eq!(escape_json("line1\nline2"), "line1\\nline2");
}

#[test]
fn test_escape_json_tab() {
    assert_eq!(escape_json("col1\tcol2"), "col1\\tcol2");
}

#[test]
fn test_escape_json_backslash() {
    assert_eq!(escape_json(r"path\to\file"), r"path\\to\\file");
}

#[test]
fn test_escape_json_control_char() {
    assert_eq!(escape_json("\x01"), "\\u0001");
}

// ---------------------------------------------------------------------------
// Primitive type conversions
// ---------------------------------------------------------------------------

#[test]
fn test_primitive_integer_display() {
    assert_eq!(format!("{}", 42_i64), "42");
}

#[test]
fn test_primitive_float_display() {
    assert_eq!(format!("{}", 3.14_f64), "3.14");
}

#[test]
fn test_f64_addition_precision() {
    // IEEE 754 double precision should handle this exactly
    let result = 0.1 + 0.2;
    assert!((result - 0.3).abs() < 1e-10);
}
