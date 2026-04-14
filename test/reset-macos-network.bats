#!/usr/bin/env bats
# test/reset-macos-network.bats — tests for reset-macos-network.sh
# Covers: --dry-run, --flush-static --dry-run, --flush-dns-resolvers --dry-run,
#         --keep-default --dry-run, bad args.
# All tests use --dry-run so no root is required.

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

@test "reset: --help exits 0 and prints usage" {
  run_script reset-macos-network.sh --help
  assert_success
  assert_output --partial "Usage:"
}

# -- --dry-run (full reset)──────

@test "reset: --dry-run exits 0" {
  run_script reset-macos-network.sh --dry-run --yes
  assert_success
}

@test "reset: --dry-run prints DRY-RUN for flush commands" {
  run_script reset-macos-network.sh --dry-run --yes
  assert_success
  assert_output --partial "DRY-RUN"
}

# -- --flush-static --dry-run────

@test "reset: --flush-static --dry-run exits 0" {
  run_script reset-macos-network.sh --flush-static --dry-run --yes
  assert_success
  assert_output --partial "DRY-RUN"
}

# -- --flush-dns-resolvers --dry-run

@test "reset: --flush-dns-resolvers --dry-run exits 0" {
  run_script reset-macos-network.sh --flush-dns-resolvers --dry-run --yes
  assert_success
  assert_output --partial "DRY-RUN"
}

# -- --keep-default --dry-run────

@test "reset: --keep-default --dry-run exits 0" {
  run_script reset-macos-network.sh --keep-default --dry-run --yes
  assert_success
  assert_output --partial "DRY-RUN"
}

# -- --backup --dry-run──────────

@test "reset: --backup --dry-run exits 0" {
  run_script reset-macos-network.sh --backup --dry-run --yes
  assert_success
}

# -- bad args───────────────────

@test "reset: unknown flag exits non-zero" {
  run_script reset-macos-network.sh --not-a-real-flag
  assert_failure
}
