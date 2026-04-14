BATS     := test/libs/bats-core/bin/bats
TEST_DIR := test
SCRIPTS  := dns-macos-routes.sh add-macos-routes.sh clean-macos-routes.sh \
            diagnose-macos-routes.sh watch-macos-routes.sh \
            backup-restore-routes.sh reset-macos-network.sh \
            lib/common.sh

# Optional: GNU timeout (gtimeout on macOS via `brew install coreutils`).
# If present, each test file is limited to 60 s so a hung test can't block CI.
_TIMEOUT_BIN := $(firstword $(wildcard $(addsuffix /gtimeout,$(subst :, ,$(PATH)))) \
                             $(wildcard $(addsuffix /timeout,$(subst :, ,$(PATH)))))
ifneq ($(_TIMEOUT_BIN),)
  _WRAP := $(_TIMEOUT_BIN) 60
else
  _WRAP :=
endif

TEST_FILES := test/add-macos-routes.bats \
              test/backup-restore-routes.bats \
              test/clean-macos-routes.bats \
              test/diagnose-macos-routes.bats \
              test/dns-macos-routes.bats \
              test/reset-macos-network.bats

.PHONY: help test lint lint-scripts lint-tests all install-hooks setup _check-timeout

help:
	@echo "Targets:"
	@echo "  make setup         First-time setup: init submodules + install git hooks"
	@echo "  make test          Run all bats unit tests"
	@echo "  make lint          Syntax-check all scripts and test files"
	@echo "  make lint-scripts  bash -n on production scripts only"
	@echo "  make lint-tests    bash -n on test/*.bats files only"
	@echo "  make all           lint + test"
	@echo "  make install-hooks Install git pre-push hook"

all: lint test

setup:
	@echo "==> Initialising submodules…"
	git submodule update --init --recursive
	@$(MAKE) install-hooks

## ── lint ────────────────────────────────────────────────────────────────────

lint: lint-scripts lint-tests

lint-scripts:
	@echo "==> Checking script syntax…"
	@for f in $(SCRIPTS); do \
	  bash -n "$$f" && echo "  OK  $$f" || { echo "  FAIL  $$f"; exit 1; }; \
	done

lint-tests: _check-bats
	@echo "==> Checking test file syntax…"
	@for f in $(TEST_DIR)/*.bats; do \
	  $(BATS) --count "$$f" > /dev/null && echo "  OK  $$f" || { echo "  FAIL  $$f"; exit 1; }; \
	done

## ── test ────────────────────────────────────────────────────────────────────

test: _check-bats _check-timeout
	@for f in $(TEST_FILES); do \
	  $(_WRAP) $(BATS) "$$f" || exit 1; \
	done

test-%: _check-bats _check-timeout
	$(_WRAP) $(BATS) $(TEST_DIR)/$*.bats

install-hooks:
	@cp scripts/pre-push .git/hooks/pre-push
	@chmod +x .git/hooks/pre-push
	@echo "pre-push hook installed."

_check-bats:
	@if [ ! -x "$(BATS)" ]; then \
	  echo "ERROR: bats not found at $(BATS)"; \
	  echo "       Run: git submodule update --init --recursive"; \
	  exit 1; \
	fi

_check-timeout:
	@if [ -z "$(_TIMEOUT_BIN)" ]; then \
	  echo "NOTE: 'timeout' (GNU coreutils) not found — tests run without a time limit."; \
	  echo "      Install with: brew install coreutils"; \
	else \
	  echo "==> Using $(_TIMEOUT_BIN) (60 s per test file)"; \
	fi
