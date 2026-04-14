#!/usr/bin/env bats
# test/add-macos-routes.bats — tests for add-macos-routes.sh
# Covers: --list, --show, --diff, --dry-run apply, --delete, --rename, bad args.

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

@test "add: --help exits 0 and prints usage" {
  run_script add-macos-routes.sh --help
  assert_success
  assert_output --partial "Usage:"
}

# -- --list─────────────────────

@test "add: --list shows set names from fixture" {
  run_script add-macos-routes.sh --list --load "${TEST_CONFIG}"
  assert_success
  assert_output --partial "office"
  assert_output --partial "vpn"
}

@test "add: --list on empty config exits 0 and shows no sets" {
  run_script add-macos-routes.sh --list --load "${FIXTURE_EMPTY}"
  assert_success
  refute_output --partial "office"
}

@test "add: --list on invalid JSON exits non-zero" {
  run_script add-macos-routes.sh --list --load "${FIXTURE_INVALID}"
  assert_failure
}

@test "add: --list on missing file exits non-zero" {
  run_script add-macos-routes.sh --list --load "/nonexistent/routes.json"
  assert_failure
}

# -- --show─────────────────────

@test "add: --show prints route details" {
  run_script add-macos-routes.sh --show --load "${TEST_CONFIG}"
  assert_success
  assert_output --partial "10.0.0.0"
  assert_output --partial "192.168.1.1"
}

# -- --diff─────────────────────

@test "add: --diff office exits 0 and reports route status" {
  run_script add-macos-routes.sh --diff office --load "${TEST_CONFIG}"
  # exit code 0 = all present, 1 = some missing — both are valid non-crash exits
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  assert_output --partial "10.0.0.0"
}

@test "add: --diff on unknown set exits non-zero" {
  run_script add-macos-routes.sh --diff nosuchset --load "${TEST_CONFIG}"
  assert_failure
}

# -- --apply (dry-run)──────────

@test "add: --dry-run --apply office prints route add commands" {
  run_script add-macos-routes.sh --dry-run --apply office --load "${TEST_CONFIG}"
  assert_success
  assert_output --partial "DRY-RUN"
  assert_output --partial "10.0.0.0"
}

@test "add: --dry-run --apply multiple sets prints all routes" {
  run_script add-macos-routes.sh --dry-run --apply office vpn --load "${TEST_CONFIG}"
  assert_success
  assert_output --partial "10.0.0.0"
  assert_output --partial "10.50.0.0"
}

@test "add: --apply unknown set exits non-zero" {
  run_script add-macos-routes.sh --dry-run --apply nosuchset --load "${TEST_CONFIG}" --yes
  assert_failure
}

# -- --delete───────────────────

@test "add: --delete removes a set from JSON" {
  run_script add-macos-routes.sh --delete vpn --load "${TEST_CONFIG}" --yes
  assert_success
  run_script add-macos-routes.sh --list --load "${TEST_CONFIG}"
  refute_output --partial "vpn"
  assert_output --partial "office"
}

@test "add: --delete unknown set exits non-zero" {
  run_script add-macos-routes.sh --delete nosuchset --load "${TEST_CONFIG}" --yes
  assert_failure
}

# -- --rename───────────────────

@test "add: --rename renames a set in JSON" {
  run_script add-macos-routes.sh --rename office office2 --load "${TEST_CONFIG}" --yes
  assert_success
  run_script add-macos-routes.sh --list --load "${TEST_CONFIG}"
  assert_output --partial "office2"
  assert_output --partial "vpn"
  # The old name "office" should only appear as part of "office2", not as a standalone entry
  # Verify by checking the python helper renamed it correctly (office2 present, output has 2 sets)
  run python3 -c "
import json
with open('${TEST_CONFIG}') as f:
    d = json.load(f)
sets = list(d['sets'].keys())
assert 'office2' in sets, f'office2 not found: {sets}'
assert 'office' not in sets, f'office still in sets: {sets}'
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "add: --rename unknown set exits non-zero" {
  run_script add-macos-routes.sh --rename nosuchset newname --load "${TEST_CONFIG}"
  assert_failure
}

# -- bad args───────────────────

@test "add: unknown flag exits non-zero" {
  run_script add-macos-routes.sh --not-a-real-flag
  assert_failure
}

@test "add: no action exits non-zero" {
  run_script add-macos-routes.sh --load "${TEST_CONFIG}"
  assert_failure
}
