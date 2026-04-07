.PHONY: test test-all test-verbose clean install-luaunit help lint

# Default target
help:
	@echo "Available targets:"
	@echo "  test            - Run all tests (or specific tests with PATTERN=...)"
	@echo "  clean           - Clean test cache files"
	@echo ""
	@echo "Examples:"
	@echo "  make test                               # Run all tests"
	@echo "  make test PATTERN=write_file            # Match test/**/*write_file*_spec.lua"
	@echo "  make test PATTERN=git_add               # Match test/**/*git_add*_spec.lua"
	@echo "  make test PATTERN=test/tools/git_add_spec.lua  # Full path"

# Run tests with nvim headless
# Supports PATTERN parameter to run specific test file(s)
# Examples:
#   make test PATTERN=test/tools/write_file_spec.lua
#   make test PATTERN=write_file  (shorthand for test/**/*write_file*_spec.lua)
test:
	@echo "Running tests with nvim --headless..."
	@nvim --headless -u NONE \
		-c "lua package.path = 'lua/?.lua;test/?.lua;' .. package.path" \
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
