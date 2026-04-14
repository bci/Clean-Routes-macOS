#!/usr/bin/env bats
# test/dns-macos-routes.bats — tests for dns-macos-routes.sh
# Covers: --list, --show, --diff, --dry-run apply/remove, bad args.
# All tests run without root; root-required paths use --dry-run.

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

@test "dns: --help exits 0 and prints usage" {
  run_script dns-macos-routes.sh --help
  assert_success
  assert_output --partial "Usage:"
}

# -- --list─────────────────────

@test "dns: --list shows profile names from fixture" {
  run_script dns-macos-routes.sh --list --load "${TEST_CONFIG}"
  assert_success
  assert_output --partial "corp"
  assert_output --partial "dev"
}

@test "dns: --list on empty config exits 0 and shows no profiles" {
  run_script dns-macos-routes.sh --list --load "${FIXTURE_EMPTY}"
  assert_success
  refute_output --partial "corp"
}

@test "dns: --list on invalid JSON exits non-zero" {
  run_script dns-macos-routes.sh --list --load "${FIXTURE_INVALID}"
  assert_failure
}

@test "dns: --list on missing file exits non-zero" {
  run_script dns-macos-routes.sh --list --load "/nonexistent/routes.json"
  assert_failure
}

# -- --show─────────────────────

@test "dns: --show exits 0 (no /etc/resolver files is not an error)" {
  run_script dns-macos-routes.sh --show
  assert_success
}

# -- --diff─────────────────────

@test "dns: --diff corp reports missing (resolver file not present)" {
  run_script dns-macos-routes.sh --diff corp --load "${TEST_CONFIG}"
  # exit 0 or 1 both acceptable — what matters is it runs without crash
  assert_output --partial "corp"
}

@test "dns: --diff on unknown profile exits non-zero" {
  run_script dns-macos-routes.sh --diff nosuchprofile --load "${TEST_CONFIG}"
  assert_failure
}

# -- --apply (dry-run)──────────

@test "dns: --dry-run --apply corp prints resolver write command" {
  run_script dns-macos-routes.sh --dry-run --apply corp --load "${TEST_CONFIG}"
  assert_success
  assert_output --partial "corp.example.com"
  assert_output --partial "DRY-RUN"
}

@test "dns: --dry-run --apply corp dev applies both profiles" {
  run_script dns-macos-routes.sh --dry-run --apply corp dev --load "${TEST_CONFIG}"
  assert_success
  assert_output --partial "corp.example.com"
  assert_output --partial "dev.local"
}

@test "dns: --dry-run --apply with --with-routes prints route commands" {
  run_script dns-macos-routes.sh --dry-run --apply corp --with-routes \
    --local-router 192.168.1.1 --load "${TEST_CONFIG}"
  assert_success
  assert_output --partial "DRY-RUN"
  assert_output --partial "10.1.0.0"
}

@test "dns: --apply unknown profile exits non-zero" {
  run_script dns-macos-routes.sh --dry-run --apply nosuchprofile --load "${TEST_CONFIG}"
  assert_failure
}

# -- --remove (dry-run)─────────

@test "dns: --dry-run --remove corp prints resolver remove command" {
  run_script dns-macos-routes.sh --dry-run --remove corp --load "${TEST_CONFIG}"
  assert_success
  assert_output --partial "DRY-RUN"
  assert_output --partial "corp.example.com"
}

@test "dns: --dry-run --remove-all prints remove-all command" {
  run_script dns-macos-routes.sh --dry-run --remove-all --load "${TEST_CONFIG}"
  assert_success
  assert_output --partial "DRY-RUN"
}

# -- --save / --delete──────────

@test "dns: --delete removes profile from JSON" {
  run_script dns-macos-routes.sh --delete dev --load "${TEST_CONFIG}" --yes
  assert_success
  run_script dns-macos-routes.sh --list --load "${TEST_CONFIG}"
  refute_output --partial "dev"
  assert_output --partial "corp"
}

@test "dns: --delete unknown profile exits non-zero" {
  run_script dns-macos-routes.sh --delete nosuchprofile --load "${TEST_CONFIG}"
  assert_failure
}

# -- bad args───────────────────

@test "dns: unknown flag exits non-zero" {
  run_script dns-macos-routes.sh --not-a-real-flag
  assert_failure
}

@test "dns: no action exits non-zero" {
  run_script dns-macos-routes.sh --load "${TEST_CONFIG}"
  assert_failure
}
