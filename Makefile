.PHONY: test test-all test-verbose clean install-deps install-luaunit install-job help lint

# Default target
help:
	@echo "Available targets:"
	@echo "  test            - Run all tests (or specific tests with PATTERN=...)"
	@echo "  clean           - Clean test cache files"
	@echo "  install-deps    - Download all test dependencies"
	@echo "  install-luaunit - Download luaunit test framework"
	@echo "  install-job     - Download job.nvim mock module"
	@echo ""
	@echo "Examples:"
	@echo "  make test                               # Run all tests"
	@echo "  make test PATTERN=write_file            # Match test/**/*write_file*_spec.lua"
	@echo "  make test PATTERN=git_add               # Match test/**/*git_add*_spec.lua"
	@echo "  make test PATTERN=test/tools/git_add_spec.lua  # Full path"

# Install all test dependencies
install-deps: install-luaunit install-job
	@echo "All dependencies installed."

# Install luaunit test framework
install-luaunit:
	@echo "Installing luaunit..."
	@mkdir -p test/.deps
	@if [ ! -f test/.deps/luaunit.lua ]; then \
		curl -fsSL https://raw.githubusercontent.com/bluebird75/luaunit/main/luaunit.lua \
			-o test/.deps/luaunit.lua; \
		echo "luaunit installed to test/.deps/luaunit.lua"; \
	else \
		echo "luaunit already installed"; \
	fi

# Install job.nvim mock module
install-job:
	@echo "Installing job.nvim..."
	@mkdir -p test/.deps
	@if [ ! -f test/.deps/job.lua ]; then \
		curl -fsSL https://raw.githubusercontent.com/wsdjeg/job.nvim/refs/heads/master/lua/job/init.lua \
			-o test/.deps/job.lua; \
		echo "job.nvim installed to test/.deps/job.lua"; \
	else \
		echo "job.nvim already installed"; \
	fi

# Run tests with nvim headless
# Supports PATTERN parameter to run specific test file(s)
# Examples:
#   make test PATTERN=test/tools/write_file_spec.lua
#   make test PATTERN=write_file  (shorthand for test/**/*write_file*_spec.lua)
test: install-deps
	@echo "Running tests with nvim --headless..."
	@nvim --headless -u test/minimal_init.lua \
		-c "lua _G.TEST_PATTERN = '$(PATTERN)'" \
		-c "lua dofile('test/run.lua')" \
		-c "qa!"

# Clean generated files
clean:
	@echo "Cleaning up..."
	@rm -rf test/*.lua~
	@rm -rf test/*.out
	@rm -rf *.swp
	@rm -rf /tmp/chat_nvim_test_* 2>/dev/null || true
