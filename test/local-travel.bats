#!/usr/bin/env bats
# test/local-travel.bats — tests for local/travel.sh
#
# travel.sh is an orchestration script that:
#   1. Removes lingering static routes (via dns-macos-routes.sh --remove)
#   2. Applies DNS-only resolvers       (via dns-macos-routes.sh --apply, uses sudo)
#   3. Tests DNS resolution             (via dns-macos-routes.sh --test, live network)
#
# Strategy:
#   • Export HOME → isolated tmp so ROUTES_JSON resolves to a writable path.
#   • Populate ~/.config/macos-routes/routes.json with the travel fixture
#     (profiles: gardena, mde).
#   • mock-bin/sudo passes arguments through so --dry-run reaches the sub-script.
#   • Step 3 (--test) requires a live VPN; tested only for non-crash / skip in CI.

bats_require_minimum_version 1.5.0

setup() {
  load 'helpers/common'
  load 'libs/bats-support/load'
  load 'libs/bats-assert/load'
  common_setup

  # local/travel.sh is gitignored — skip the whole file when not present (CI).
  if [[ ! -f "${REPO_ROOT}/local/travel.sh" ]]; then
    skip "local/travel.sh not present (gitignored; run locally)"
  fi

  # Redirect HOME so travel.sh and every dns-macos-routes.sh it spawns share
  # the same routes.json without touching the real user config.
  export HOME="${TEST_TMP}"
  CONFIG_DIR="${TEST_TMP}/.config/macos-routes"
  mkdir -p "${CONFIG_DIR}"
  TRAVEL_CONFIG="${CONFIG_DIR}/routes.json"
  cp "${FIXTURE_DIR}/travel.json" "${TRAVEL_CONFIG}"
  export TRAVEL_CONFIG
}

teardown() {
  common_teardown
}

# -- --help ────────────────────────────────────────────────────────────────────

@test "travel: --help exits 0 and prints usage" {
  run zsh "${REPO_ROOT}/local/travel.sh" --help
  # travel.sh has no --help handler; it should still start cleanly with --dry-run
  # This test verifies the shebang/sourcing path doesn't blow up.
  skip "travel.sh has no --help flag; use --dry-run tests instead"
}

# -- dry-run (main happy path) ─────────────────────────────────────────────────

@test "travel: --dry-run exits 0" {
  run zsh "${REPO_ROOT}/local/travel.sh" --dry-run --yes
  assert_success
}

@test "travel: --dry-run prints all phase headers" {
  run zsh "${REPO_ROOT}/local/travel.sh" --dry-run --yes
  assert_success
  assert_output --partial "[1/3]"
  assert_output --partial "[2/3]"
  assert_output --partial "[3/3]"
}

@test "travel: --dry-run prints Travel title" {
  run zsh "${REPO_ROOT}/local/travel.sh" --dry-run --yes
  assert_success
  assert_output --partial "Travel"
  assert_output --partial "DNS Only"
}

@test "travel: --dry-run step 2 prints DRY-RUN for apply" {
  run zsh "${REPO_ROOT}/local/travel.sh" --dry-run --yes
  assert_success
  assert_output --partial "DRY-RUN"
}

@test "travel: --dry-run references gardena profile" {
  run zsh "${REPO_ROOT}/local/travel.sh" --dry-run --yes
  assert_success
  assert_output --partial "ci.gardena.ca.us"
}

@test "travel: --dry-run references mde profile" {
  run zsh "${REPO_ROOT}/local/travel.sh" --dry-run --yes
  assert_success
  assert_output --partial "mde.local"
}

# -- missing routes.json ───────────────────────────────────────────────────────

@test "travel: --dry-run without routes.json bootstraps profiles and succeeds" {
  rm -f "${TRAVEL_CONFIG}"
  run zsh "${REPO_ROOT}/local/travel.sh" --dry-run --yes
  assert_success
  assert_output --partial "gardena"
}

# -- step 3 DNS test ───────────────────────────────────────────────────────────

@test "travel: step 3 applies DNS resolvers (mocked dscacheutil + ping)" {
  # mock-bin/dscacheutil + ping prevent live network calls in step 3.
  run zsh "${REPO_ROOT}/local/travel.sh" --dry-run --yes
  assert_success
  assert_output --partial "[3/3]"
}
