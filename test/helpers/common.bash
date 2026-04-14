#!/usr/bin/env zsh
# test/helpers/common.bash — shared setup/teardown for all .bats test files
#
# Usage in a .bats file:
#   load 'helpers/common'

# Absolute path to the repo root (one level up from test/)
REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

# Fixture paths
FIXTURE_DIR="${REPO_ROOT}/test/fixtures"
FIXTURE_FULL="${FIXTURE_DIR}/routes.json"
export FIXTURE_EMPTY="${FIXTURE_DIR}/empty.json"
export FIXTURE_INVALID="${FIXTURE_DIR}/invalid.json"

# ---------------------------------------------------------------------------
# common_setup — call from setup() in each .bats file
#   • Creates an isolated tmp dir for this test run
#   • Copies the full fixture into it so tests can mutate freely
#   • Sets TEST_CONFIG pointing at the mutable copy
#   • Sets TEST_TMP for any other temp artefacts
# ---------------------------------------------------------------------------
common_setup() {
  TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bats-routes.XXXXXX")"
  TEST_CONFIG="${TEST_TMP}/routes.json"
  cp "${FIXTURE_FULL}" "${TEST_CONFIG}"
  export TEST_TMP TEST_CONFIG REPO_ROOT

  # Prepend mock-bin so tests never call the real networksetup (which can hang)
  MOCK_BIN="${REPO_ROOT}/test/helpers/mock-bin"
  chmod +x "${MOCK_BIN}/networksetup"
  export PATH="${MOCK_BIN}:${PATH}"
}

# ---------------------------------------------------------------------------
# common_teardown — call from teardown() in each .bats file
# ---------------------------------------------------------------------------
common_teardown() {
  rm -rf "${TEST_TMP:-}"
}

# ---------------------------------------------------------------------------
# run_script <script-name> [args…]
#   Convenience wrapper — runs a script from REPO_ROOT.
#   Captures status/output via bats `run`.
# ---------------------------------------------------------------------------
run_script() {
  local script="${REPO_ROOT}/${1}"
  shift
  run zsh "${script}" "$@"
}

# ---------------------------------------------------------------------------
# skip_if_ci [reason]
#   Skip a test when running in GitHub Actions (CI=true).
#   Use for tests that require live network, real /etc/resolver/, or sudo.
# ---------------------------------------------------------------------------
skip_if_ci() {
  if [[ "${CI:-}" == "true" ]]; then
    skip "${1:-skipped in CI}"
  fi
}

# ---------------------------------------------------------------------------
# skip_if_not_root [reason]
#   Skip a test unless running as root.
#   In CI, also skips (CI runners don't run bats as root).
# ---------------------------------------------------------------------------
skip_if_not_root() {
  if [[ $EUID -ne 0 ]]; then
    skip "${1:-requires root}"
  fi
}
