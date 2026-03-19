-- Global variables for Neovim plugins
globals = {
    "vim",
}

-- Standard settings
std = "luajit"

-- Allow unused arguments (common in tests)
unused_args = false

-- Allow unused self in methods
self = false

-- Allow defining globals in test files
files["test/"] = {
    globals = {
        "vim",
    },
}

-- Ignore whitespace warnings
ignore = {
    -- "631", -- line contains only whitespace
}

