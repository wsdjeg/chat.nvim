.PHONY: test test-all test-verbose clean install-luaunit help lint

# Default target
help:
	@echo "Available targets:"
	@echo "  test            - Run all tests with nvim --headless"
	@echo "  test-all        - Run all tests (alias for test)"
	@echo "  test-verbose    - Run tests with verbose output"
	@echo "  install-luaunit - Install luaunit using luarocks"
	@echo "  lint            - Run luacheck on source files"
	@echo "  clean           - Clean test cache files"

# Run tests with nvim headless
test:
	@echo "Running tests with nvim --headless..."
	@nvim --headless -u NONE \
		-c "lua package.path = 'lua/?.lua;test/?.lua;' .. package.path" \
		-c "lua dofile('test/run.lua')" \
		-c "qa!"

# Run all tests (alias)
test-all: test

# Run tests with verbose output
test-verbose:
	@echo "Running tests with verbose output..."
	@nvim --headless -u NONE \
		-c "lua package.path = 'lua/?.lua;test/?.lua;' .. package.path" \
		-c "lua dofile('test/run.lua')" \
		# -c "qa!" 2>&1

# Install luaunit
install-luaunit:
	@echo "Installing luaunit..."
	@luarocks install luaunit

# Run linter
lint:
	@echo "Running luacheck..."
	@luacheck lua/*.lua lua/**/*.lua test/*.lua test/**/*.lua

# Clean generated files
clean:
	@echo "Cleaning up..."
	@rm -rf test/*.lua~
	@rm -rf test/*.out
	@rm -rf *.swp
	@rm -rf /tmp/chat_nvim_test_* 2>/dev/null || true
