.PHONY: test coverage clean install-deps install-luaunit install-job junit help

# ---------------------------------------------------------------------------
# Test dependencies (luaunit, job.nvim, luacov) live in test/.deps.
#
# `test` used to depend on the `install-deps` target, which spawns a whole
# extra headless nvim on every run just to print "already installed". That
# startup is several seconds even when nothing is downloaded, and for a small
# `make test PATTERN=foo` it can outweigh the tests themselves.
#
# A stamp file makes the check free: the installer only runs when the stamp is
# missing (first run, new checkout, or when test/install_deps.lua changes).
# Delete test/.deps, or run `make install-deps`, to force a re-download.
# ---------------------------------------------------------------------------
DEPS_STAMP := test/.deps/.installed

$(DEPS_STAMP): test/install_deps.lua
	@nvim --headless -u test/minimal_init.lua -c "lua dofile('test/install_deps.lua')" -c "qa!"
	@touch $(DEPS_STAMP)

# ---------------------------------------------------------------------------
# Passing Make variables to headless nvim: use the environment, not a
# POSIX-style inline prefix.
#
#   PROFILE='$(PROFILE)' nvim ...        <-- broken on Windows
#   COVERAGE=1 nvim ...                  <-- broken on Windows
#
# `VAR=value cmd` is shell syntax. On Windows make hands the recipe line to
# cmd.exe, which takes `PROFILE='1' nvim ...` as the name of a single program
# to run, so every `make test PROFILE=1` / `make coverage` invocation dies with
# "not recognized as an internal or external command".
#
# GNU Make's `export` directive puts the variable straight into the child
# process environment, independent of the shell (cmd.exe, sh, PowerShell,
# zsh...), so the recipe stays a single plain command on every platform.
#
# COVERAGE in particular must already be in the environment when
# test/minimal_init.lua is sourced (luacov has to hook before any plugin
# source loads), so it cannot be passed with a `-c "lua vim.env.COVERAGE=..."`
# line either - that runs after the init file.
# ---------------------------------------------------------------------------
export PROFILE
export COVERAGE

# Default target
help:
	@echo "Available targets:"
	@echo "  test            - Run all tests (or specific tests with PATTERN=...)"
	@echo "  coverage        - Run tests with luacov and report line coverage"
	@echo "  clean           - Clean test cache files"
	@echo "  install-deps    - Download all test dependencies"
	@echo "  install-luaunit - Download luaunit test framework"
	@echo "  install-job     - Download job.nvim mock module"
	@echo "  junit           - Download junit artifact from CI (ARTIFACT_ID=<id>)"
	@echo ""
	@echo "Examples:"
	@echo "  make test                               # Run all tests"
	@echo "  make test PATTERN=write_file            # Match test/**/*write_file*_spec.lua"
	@echo "  make test PATTERN=git_add               # Match test/**/*git_add*_spec.lua"
	@echo "  make test PATTERN=test/tools/git_add_spec.lua  # Full path"
	@echo "  make test PROFILE=1                     # Report slowest tests/classes"
	@echo "  make coverage                           # Run tests and report coverage"
	@echo "  make coverage COV_THRESHOLD=80          # Fail when coverage < 80%"

# Install all test dependencies (cross-platform, uses Lua).
# Always re-runs the installer, which is idempotent and skips existing files.
install-deps:
	@nvim --headless -u test/minimal_init.lua -c "lua dofile('test/install_deps.lua')" -c "qa!"
	@touch $(DEPS_STAMP)

# Aliases for individual dependency install (same cross-platform Lua script)
install-luaunit: install-deps
install-job: install-deps

# Run tests with nvim headless
# Supports PATTERN parameter to run specific test file(s)
# Examples:
#   make test PATTERN=test/tools/write_file_spec.lua
#   make test PATTERN=write_file  (shorthand for test/**/*write_file*_spec.lua)
# PROFILE=1 is handed to nvim through the exported environment (see above).
test: $(DEPS_STAMP)
	@echo "Running tests with nvim --headless..."
	@nvim --headless -u test/minimal_init.lua \
		-c "lua _G.TEST_PATTERN = '$(PATTERN)'" \
		-c "lua dofile('test/run.lua')" \
		-c "qa!"

# Run tests with line coverage (luacov) and report the result.
# COVERAGE=1 enables luacov in test/minimal_init.lua; the report step
# parses luacov.stats.out. Report-only by default, enforce a threshold
# with COV_THRESHOLD=<n> (overall % across lua/chat/**).
#
# COVERAGE=1 is a target-specific *exported* variable, so it reaches nvim
# through its environment on every platform (cmd.exe included) instead of
# the POSIX-only `COVERAGE=1 nvim ...` prefix. It must be available before
# test/minimal_init.lua is sourced, so a `-c "lua ..."` line would be too late.
coverage: export COVERAGE := 1
coverage: $(DEPS_STAMP)
	@echo "Running tests with coverage..."
	@rm -f luacov.stats.out luacov.report.out coverage.log
	@nvim --headless -u test/minimal_init.lua \
		-c "lua _G.TEST_PATTERN = '$(PATTERN)'" \
		-c "lua dofile('test/run.lua')" \
		-c "qa!"
	@nvim --headless -u test/minimal_init.lua \
		-c "lua dofile('test/coverage_report.lua')" \
		-c "qa!" > coverage.log 2>&1 \
		|| { cat coverage.log; exit 1; }
	@cat coverage.log

# Clean generated files
clean:
	@echo "Cleaning up..."
	@rm -rf test/*.lua~
	@rm -rf test/*.out
	@rm -rf luacov.stats.out luacov.report.out coverage.log profile.log
	@rm -rf *.swp
	@rm -rf /tmp/chat_nvim_test_* 2>/dev/null || true

# Download a junit XML artifact from GitHub Actions and print it.
# Uses nightly.link (no auth needed for public repos); falls back to
# GitHub API if GITHUB_TOKEN is set.
#   make junit ARTIFACT_ID=9277505915 ARTIFACT_NAME=junit-Windows-stable
junit:
	@rm -rf .junit && mkdir -p .junit
	@if curl -sfL -o .junit/junit.zip \
		"https://nightly.link/wsdjeg/chat.nvim/actions/artifacts/$(ARTIFACT_ID).zip"; then \
		echo "downloaded via nightly.link"; \
	elif [ -n "$(GITHUB_TOKEN)" ]; then \
		curl -sfL -H "Authorization: Bearer $(GITHUB_TOKEN)" \
			-o .junit/junit.zip \
			"https://api.github.com/repos/wsdjeg/chat.nvim/actions/artifacts/$(ARTIFACT_ID)/zip"; \
	else \
		echo "download failed: nightly.link unavailable and GITHUB_TOKEN not set" >&2; \
		exit 1; \
	fi
	@cd .junit && { unzip -o junit.zip 2>/dev/null \
		|| python3 -c "import zipfile; zipfile.ZipFile('junit.zip').extractall('.')" \
		|| busybox unzip -o junit.zip; }
	@ls -la .junit/

