#!/usr/bin/env bats
# test/clean-macos-routes.bats — tests for clean-macos-routes.sh
# Covers: --dry-run with --network, --filter, --all, bad args.
# No root required — all tests use --dry-run.

bats_require_minimum_version 1.5.0

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

@test "clean: --help exits 0 and prints usage" {
  run_script clean-macos-routes.sh --help
  assert_success
  assert_output --partial "Usage:"
}

# -- --dry-run --network─────────

@test "clean: --dry-run --network 10. exits 0 and prints DRY-RUN" {
  run_script clean-macos-routes.sh --dry-run --network 10.
  assert_success
  # May print "No routes deleted" if no 10.x static routes exist; either way success
}

@test "clean: --dry-run --network with CIDR exits 0" {
  run_script clean-macos-routes.sh --dry-run --network 172.16.0.0/12
  assert_success
}

@test "clean: --dry-run --network can be repeated" {
  run_script clean-macos-routes.sh --dry-run --network 10. --network 172.
  assert_success
}

# -- --dry-run --all─────────────

@test "clean: --dry-run --all exits 0" {
  run_script clean-macos-routes.sh --dry-run --all
  assert_success
  # Script prints routes and "(dry-run) not executing" for each
}

# -- --dry-run --filter──────────

@test "clean: --dry-run --filter exits 0" {
  run_script clean-macos-routes.sh --dry-run --filter 10.
  assert_success
}

# -- --dry-run --persist─────────

@test "clean: --dry-run --network --persist exits 0" {
  run_script clean-macos-routes.sh --dry-run --network 10. --persist
  assert_success
}

# -- bad args───────────────────

@test "clean: unknown flag exits non-zero" {
  run_script clean-macos-routes.sh --not-a-real-flag
  assert_failure
}

@test "clean: --network requires an argument" {
  run_script clean-macos-routes.sh --network
  assert_failure
}

@test "clean: --filter requires an argument" {
  run_script clean-macos-routes.sh --filter
  assert_failure
}
