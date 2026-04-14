#!/usr/bin/env bats
# test/diagnose-macos-routes.bats — tests for diagnose-macos-routes.sh
# Covers: default run, --json, --all, --ipv4, --ipv6, --help, bad args.
# No root required — script is fully read-only.

bats_require_minimum_version 1.5.0
export BATS_TEST_TIMEOUT=15   # seconds per test — prevents network calls hanging

setup() {
  load 'helpers/common'
  load 'libs/bats-support/load'
  load 'libs/bats-assert/load'
  common_setup
}

teardown() {
  common_teardown
}

# -- --help─────────────────────

@test "diagnose: --help exits 0 and prints usage" {
  run_script diagnose-macos-routes.sh --help
  assert_success
  assert_output --partial "Usage:"
}

# -- default run─────────────────

@test "diagnose: default run exits 0 and contains key sections" {
  skip_if_ci "runs live netstat/scutil — tested locally only"
  run_script diagnose-macos-routes.sh
  assert_success
  assert_output --partial "Routing Table"
  assert_output --partial "Conditional DNS"
}

# -- --ipv4 / --ipv6 / --all────

@test "diagnose: --ipv4 exits 0" {
  skip_if_ci "runs live netstat — tested locally only"
  run_script diagnose-macos-routes.sh --ipv4
  assert_success
}

@test "diagnose: --ipv6 exits 0" {
  skip_if_ci "runs live netstat — tested locally only"
  run_script diagnose-macos-routes.sh --ipv6
  assert_success
}

@test "diagnose: --all exits 0 and shows both IPv4 and IPv6 sections" {
  skip_if_ci "runs live netstat — tested locally only"
  run_script diagnose-macos-routes.sh --all
  assert_success
  assert_output --partial "IPv4"
  assert_output --partial "IPv6"
}

# -- --json──────────────────────

@test "diagnose: --json exits 0 and output is valid JSON with expected keys" {
  skip_if_ci "runs live netstat/scutil — tested locally only"
  run_script diagnose-macos-routes.sh --json
  assert_success
  assert_output --partial "conditional_dns"
  assert_output --partial "routing_table"
  echo "$output" | python3 -c "import sys, json; json.load(sys.stdin)"
}

# -- --check-gateway─────────────

@test "diagnose: --check-gateway exits 0" {
  # Skipped in environments where gateway may be unreachable or ping is blocked
  skip "live network test — run manually with: diagnose-macos-routes.sh --check-gateway"
}

# -- bad args───────────────────

@test "diagnose: unknown flag exits non-zero" {
  run_script diagnose-macos-routes.sh --not-a-real-flag
  assert_failure
}
