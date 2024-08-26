# Neotest Bazel

A Neotest adapter to run tests with Bazel.

## Installation

#### With 💤 Lazy.nvim

```lua
return {
  {
    "nvim-neotest/neotest",
    dependencies = {
      -- Neotest dependencies
      "nvim-neotest/nvim-nio",
      "nvim-lua/plenary.nvim",
      "antoinemadec/FixCursorHold.nvim",
      "nvim-treesitter/nvim-treesitter",
      -- Our adapter
      "sluongng/neotest-bazel",
    },
    config = function()
      require("neotest").setup({
        adapters = {
          -- Our adapter registration
          require("neotest-bazel"),
        },
      })
    end,
  },
}
```

## Scope

Current supported languages:

- [x] Go
- [ ] Java
- [ ] Bash
- [ ] Python

I also plan to add more configuration options to help customize Bazel runs.

Users should use `.bazelrc` and (optional) `user.bazelrc` to customize their Bazel runs as much as possible in the meantime.

Contributions are welcome!

## Current Known Issues

- Missing support for "dir" and "namespace" run mode.

- Running multiple tests under the same Bazel target could override the test log and xml.
  Neotest does not have a way to batch up multiple test runs _yet_.

- Parsing sharded XML test results is broken.

## Acknowledgements

- This was initially developed as a Hackathon project in [BuildBuddy](https://buildbuddy.io).

- Many inspirations were taken from the sister projects: [neotest-golang](https://github.com/fredrikaverpil/neotest-golang) and [neotest-java](https://github.com/andy-bell101/neotest-java).
