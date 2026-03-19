.PHONY: test test-all test-verbose clean install-luaunit help lint

# Default target
help:
	@echo "Available targets:"
	@echo "  test            - Run all tests with nvim --headless"
	@echo "  lint            - Run luacheck on source files"
	@echo "  clean           - Clean test cache files"

# Run tests with nvim headless
test:
	@echo "Running tests with nvim --headless..."
	@nvim --headless -u NONE \
		-c "lua package.path = 'lua/?.lua;test/?.lua;' .. package.path" \
		-c "lua dofile('test/run.lua')" \
		-c "qa!"

# Run linter
lint:
	@echo "Running luacheck..."
	@luacheck lua test

# Clean generated files
clean:
	@echo "Cleaning up..."
	@rm -rf test/*.lua~
	@rm -rf test/*.out
	@rm -rf *.swp
	@rm -rf /tmp/chat_nvim_test_* 2>/dev/null || true
