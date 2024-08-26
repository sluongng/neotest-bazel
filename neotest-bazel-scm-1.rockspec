rockspec_format = '3.0'
package = "neotest-bazel"
version = "scm-1"
source = {
  url = "git+https://github.com/sluongng/neotest-bazel.git",
}
dependencies = {
  "neotest",
  "plenary.nvim",
}
test_dependencies = {
  "nlua"
}
build = {
  type = "builtin",
  copy_directories = {
    -- Add runtimepath directories, like
    -- 'plugin', 'ftplugin', 'doc'
    -- here. DO NOT add 'lua' or 'lib'.
  },
}
