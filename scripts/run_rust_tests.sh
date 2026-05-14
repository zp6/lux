#!/usr/bin/env bash
#
# run_rust_tests.sh — CI script for running Rust and Elixir NIF tests.
#
# Usage:
#   ./scripts/run_rust_tests.sh            # Run all tests
#   ./scripts/run_rust_tests.sh --rust     # Rust tests only
#   ./scripts/run_rust_tests.sh --elixir   # Elixir tests only
#   ./scripts/run_rust_tests.sh --ci       # CI mode (strict, no colors)
#
# Exit codes:
#   0 — All tests passed
#   1 — Test failure
#   2 — Setup failure (missing dependencies)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUST_DIR="$PROJECT_DIR/priv/rust"

# Colors (disabled in CI mode)
if [ -t 1 ] && [ "${CI:-}" != "true" ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[PASS]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------

check_deps() {
  local missing=0

  if ! command -v cargo &>/dev/null; then
    log_fail "cargo not found. Install Rust: https://rustup.rs/"
    missing=1
  fi

  if [ "${RUN_ELIXIR:-true}" = "true" ]; then
    if ! command -v mix &>/dev/null; then
      log_fail "mix not found. Install Elixir: https://elixir-lang.org/install.html"
      missing=1
    fi
  fi

  if [ $missing -ne 0 ]; then
    exit 2
  fi

  log_ok "All dependencies found"
}

# ---------------------------------------------------------------------------
# Rust tests
# ---------------------------------------------------------------------------

run_rust_tests() {
  log_info "Running Rust tests..."

  if [ ! -d "$RUST_DIR" ]; then
    log_fail "Rust directory not found: $RUST_DIR"
    exit 1
  fi

  cd "$RUST_DIR"

  # Check formatting
  log_info "Checking Rust formatting..."
  if cargo fmt -- --check 2>/dev/null; then
    log_ok "Rust formatting OK"
  else
    log_warn "Rust formatting issues detected (run 'cargo fmt' to fix)"
    if [ "${CI:-}" = "true" ]; then
      log_fail "Formatting check required in CI"
      exit 1
    fi
  fi

  # Run clippy
  log_info "Running Clippy lints..."
  if cargo clippy -- -D warnings 2>/dev/null; then
    log_ok "Clippy passed"
  else
    log_warn "Clippy warnings detected"
    if [ "${CI:-}" = "true" ]; then
      log_fail "Clippy check required in CI"
      exit 1
    fi
  fi

  # Run tests
  log_info "Running cargo test..."
  if cargo test --verbose 2>&1; then
    log_ok "Rust tests passed"
  else
    log_fail "Rust tests FAILED"
    exit 1
  fi

  cd "$PROJECT_DIR"
}

# ---------------------------------------------------------------------------
# Elixir tests
# ---------------------------------------------------------------------------

run_elixir_tests() {
  log_info "Running Elixir NIF tests..."

  cd "$PROJECT_DIR"

  # Install dependencies
  log_info "Installing Mix dependencies..."
  mix deps.get

  # Compile (builds Rust NIF via Rustler)
  log_info "Compiling (includes Rust NIF build)..."
  mix compile

  # Run native-specific tests
  log_info "Running NIF integration tests..."
  if mix test test/native/ --trace 2>&1; then
    log_ok "Elixir NIF tests passed"
  else
    log_fail "Elixir NIF tests FAILED"
    exit 1
  fi

  # Run testing framework tests
  if [ -f "test/native/testing_test.exs" ]; then
    log_info "Running testing framework tests..."
    if mix test test/native/testing_test.exs --trace 2>&1; then
      log_ok "Testing framework tests passed"
    else
      log_fail "Testing framework tests FAILED"
      exit 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local run_rust=true
  local run_elixir=true

  case "${1:-all}" in
    --rust)    run_elixir=false ;;
    --elixir)  run_rust=false ;;
    --ci)      export CI=true ;;
    --help|-h)
      echo "Usage: $0 [--rust|--elixir|--ci|--help]"
      exit 0
      ;;
  esac

  echo ""
  echo "═══════════════════════════════════════════"
  echo "  Lux Rust Testing Framework"
  echo "═══════════════════════════════════════════"
  echo ""

  check_deps

  if [ "$run_rust" = true ]; then
    echo ""
    echo "── Rust Tests ─────────────────────────────"
    run_rust_tests
  fi

  if [ "$run_elixir" = true ]; then
    echo ""
    echo "── Elixir Tests ───────────────────────────"
    RUN_ELIXIR=true run_elixir_tests
  fi

  echo ""
  echo "═══════════════════════════════════════════"
  echo -e "  ${GREEN}All tests passed! ✓${NC}"
  echo "═══════════════════════════════════════════"
  echo ""
}

main "$@"
