#!/usr/bin/env bats
# test/local-home.bats — tests for local/home.sh
#
# home.sh is an orchestration script that:
#   1. Ensures gardena + mde DNS profiles exist in routes.json (_ensure_profile)
#   2. Updates profile networks/test hosts via inline Python
#   3. Applies DNS resolvers + static routes (sudo dns-macos-routes.sh --apply --with-routes)
#   4. Tests DNS resolution          (dns-macos-routes.sh --test)
#
# Strategy:
#   • Export HOME → isolated tmp; home.sh and sub-scripts share the same routes.json.
#   • mock-bin/sudo    — pass-through so --dry-run reaches dns-macos-routes.sh.
#   • mock-bin/dscacheutil — exits 0 silently (no live DNS).
#   • mock-bin/ping    — exits 1 instantly (unreachable warn, non-fatal).
#   • Two fixture states tested: no routes.json (cold start) and pre-populated.

bats_require_minimum_version 1.5.0

setup() {
  load 'helpers/common'
  load 'libs/bats-support/load'
  load 'libs/bats-assert/load'
  common_setup

  export HOME="${TEST_TMP}"
  CONFIG_DIR="${TEST_TMP}/.config/macos-routes"
  mkdir -p "${CONFIG_DIR}"
  HOME_CONFIG="${CONFIG_DIR}/routes.json"
  export HOME_CONFIG
}

teardown() {
  common_teardown
}

# ── helpers ───────────────────────────────────────────────────────────────────

# Seed routes.json with the travel fixture (has gardena + mde profiles)
_seed_travel_fixture() {
  cp "${FIXTURE_DIR}/travel.json" "${HOME_CONFIG}"
}

# ── --help ────────────────────────────────────────────────────────────────────

@test "home: script starts without error (no --help flag; smoke test)" {
  # home.sh has no --help handler — use --dry-run as the entry smoke test.
  skip "use --dry-run tests below as the primary entry point"
}

# ── cold start (no routes.json) ───────────────────────────────────────────────

@test "home: --dry-run exits 0 when routes.json does not exist" {
  run zsh "${REPO_ROOT}/local/home.sh" --dry-run --yes
  assert_success
}

@test "home: --dry-run creates routes.json when it does not exist" {
  run zsh "${REPO_ROOT}/local/home.sh" --dry-run --yes
  assert_success
  [ -f "${HOME_CONFIG}" ]
}

@test "home: --dry-run writes gardena profile into new routes.json" {
  run zsh "${REPO_ROOT}/local/home.sh" --dry-run --yes
  assert_success
  run python3 -c "
import json, sys
with open('${HOME_CONFIG}') as f:
    d = json.load(f)
assert 'gardena' in d['dns']['profiles'], 'gardena missing'
"
  assert_success
}

@test "home: --dry-run writes mde profile into new routes.json" {
  run zsh "${REPO_ROOT}/local/home.sh" --dry-run --yes
  assert_success
  run python3 -c "
import json, sys
with open('${HOME_CONFIG}') as f:
    d = json.load(f)
assert 'mde' in d['dns']['profiles'], 'mde missing'
"
  assert_success
}

@test "home: --dry-run sets gardena networks in routes.json" {
  run zsh "${REPO_ROOT}/local/home.sh" --dry-run --yes
  assert_success
  run python3 -c "
import json
with open('${HOME_CONFIG}') as f:
    d = json.load(f)
nets = d['dns']['profiles']['gardena'].get('networks', [])
assert '172.16.0.0/12' in nets, f'expected 172.16.0.0/12 in {nets}'
"
  assert_success
}

@test "home: --dry-run sets mde networks in routes.json" {
  run zsh "${REPO_ROOT}/local/home.sh" --dry-run --yes
  assert_success
  run python3 -c "
import json
with open('${HOME_CONFIG}') as f:
    d = json.load(f)
nets = d['dns']['profiles']['mde'].get('networks', [])
assert '10.0.0.0/24' in nets, f'expected 10.0.0.0/24 in {nets}'
"
  assert_success
}

# ── phase headers ─────────────────────────────────────────────────────────────

@test "home: --dry-run prints all phase headers" {
  run zsh "${REPO_ROOT}/local/home.sh" --dry-run --yes
  assert_success
  assert_output --partial "[1/3]"
  assert_output --partial "[2/3]"
  assert_output --partial "[3/3]"
}

@test "home: --dry-run prints Home Office title" {
  run zsh "${REPO_ROOT}/local/home.sh" --dry-run --yes
  assert_success
  assert_output --partial "Home Office"
  assert_output --partial "DNS + Routes"
}

# ── apply phase ───────────────────────────────────────────────────────────────

@test "home: --dry-run step 2 prints DRY-RUN for apply" {
  run zsh "${REPO_ROOT}/local/home.sh" --dry-run --yes
  assert_success
  assert_output --partial "DRY-RUN"
}

@test "home: --dry-run step 2 references gardena profile" {
  run zsh "${REPO_ROOT}/local/home.sh" --dry-run --yes
  assert_success
  assert_output --partial "ci.gardena.ca.us"
}

@test "home: --dry-run step 2 references mde profile" {
  run zsh "${REPO_ROOT}/local/home.sh" --dry-run --yes
  assert_success
  assert_output --partial "mde.local"
}

# ── idempotency (profiles already present) ────────────────────────────────────

@test "home: --dry-run is idempotent when profiles already exist" {
  _seed_travel_fixture
  run zsh "${REPO_ROOT}/local/home.sh" --dry-run --yes
  assert_success
}

@test "home: --dry-run does not duplicate profiles when already present" {
  _seed_travel_fixture
  run zsh "${REPO_ROOT}/local/home.sh" --dry-run --yes
  assert_success
  run python3 -c "
import json
with open('${HOME_CONFIG}') as f:
    d = json.load(f)
profiles = d['dns']['profiles']
assert list(profiles.keys()).count('gardena') == 1, 'gardena duplicated'
assert list(profiles.keys()).count('mde') == 1, 'mde duplicated'
"
  assert_success
}

# ── step 3 DNS test (mocked) ──────────────────────────────────────────────────

@test "home: step 3 dns test runs without crash (mocked dscacheutil + ping)" {
  # mock-bin/dscacheutil exits 0 with no output — no resolved IPs (non-fatal warn).
  # mock-bin/ping exits 1 instantly (unreachable) — treated as warn, not fatal.
  run zsh "${REPO_ROOT}/local/home.sh" --dry-run --yes
  assert_success
  assert_output --partial "[3/3]"
}
