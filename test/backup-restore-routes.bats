#!/usr/bin/env bats
# test/backup-restore-routes.bats — tests for backup-restore-routes.sh
# Covers: --backup, --list-backups, --diff, --dry-run restore, --prune, bad args.
# NOTE: The script stores backups in ROUTES_BACKUP_DIR (~/.config/macos-routes/backups)
#       by default.  We redirect that to TEST_TMP by overriding HOME.

bats_require_minimum_version 1.5.0

setup() {
  load 'helpers/common'
  load 'libs/bats-support/load'
  load 'libs/bats-assert/load'
  common_setup
  # Redirect HOME so all ~/.config writes go into our isolated tmp dir
  export HOME="${TEST_TMP}"
  # Convenience: explicit snapshot path for tests that need one
  SNAP="${TEST_TMP}/snap-$(date +%s).json"
  export SNAP
}

teardown() {
  common_teardown
}

# -- --help─────────────────────

@test "backup: --help exits 0 and prints usage" {
  run_script backup-restore-routes.sh --help
  assert_success
  assert_output --partial "Usage:"
}

# -- --backup (explicit path)────

@test "backup: --backup <file> exits 0 and creates the snapshot file" {
  run_script backup-restore-routes.sh --backup "${SNAP}"
  assert_success
  [ -f "${SNAP}" ]
}

@test "backup: --backup <file> --include-dns exits 0" {
  run_script backup-restore-routes.sh --backup "${SNAP}" --include-dns
  assert_success
  [ -f "${SNAP}" ]
}

# -- --backup (default path)─────

@test "backup: --backup (no path) exits 0 and creates file under HOME/.config" {
  run_script backup-restore-routes.sh --backup
  assert_success
  local count
  count=$(find "${TEST_TMP}/.config" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

# -- --list-backups──────────────

@test "backup: --list-backups with no backups exits 0" {
  # No backups created yet; default backup dir doesn't exist → exits 0 with message
  run_script backup-restore-routes.sh --list-backups
  assert_success
}

@test "backup: --list-backups shows a created backup" {
  run_script backup-restore-routes.sh --backup
  run_script backup-restore-routes.sh --list-backups
  assert_success
  # do_list strips .json, output is "<timestamp>  (<bytes> bytes)"
  assert_output --partial "bytes)"
}

# -- --diff──────────────────────

@test "backup: --diff against a snapshot exits 0 or 1 (no crash)" {
  run_script backup-restore-routes.sh --backup "${SNAP}"
  run_script backup-restore-routes.sh --diff "${SNAP}"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "backup: --diff on missing file exits non-zero" {
  run_script backup-restore-routes.sh --diff "/nonexistent/snap.json"
  assert_failure
}

# -- --restore (dry-run)─────────

@test "backup: --dry-run --restore prints DRY-RUN message" {
  run_script backup-restore-routes.sh --backup "${SNAP}"
  run_script backup-restore-routes.sh --dry-run --restore "${SNAP}"
  assert_success
  assert_output --partial "DRY-RUN"
}

@test "backup: --restore on missing file exits non-zero" {
  run_script backup-restore-routes.sh --restore "/nonexistent/snap.json"
  assert_failure
}

# -- --prune─────────────────────

@test "backup: --prune exits 0 when fewer backups than keep limit" {
  run_script backup-restore-routes.sh --backup
  run_script backup-restore-routes.sh --prune 5 --yes
  assert_success
}

# -- bad args───────────────────

@test "backup: unknown flag exits non-zero" {
  run_script backup-restore-routes.sh --not-a-real-flag
  assert_failure
}

@test "backup: no action exits non-zero" {
  run_script backup-restore-routes.sh
  assert_failure
}

@test "backup: --restore requires a path argument" {
  run_script backup-restore-routes.sh --restore
  assert_failure
}
