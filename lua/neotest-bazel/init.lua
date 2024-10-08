local logger = require("neotest.logging")
local process = require("neotest.lib.process")

local M = {}

--- See neotest.Adapter for the full interface.
--- @class Adapter : neotest.Adapter
--- @field name string
M.Adapter = {
  name = "neotest-bazel",
  init = function() end,
}

---Find the project root directory given a current directory to work from.
---Should no root be found, the adapter can still be used in a non-project context if a test file matches.
---@async
---@param _dir string @Directory to treat as cwd
---@return string | nil @Absolute root dir of test suite
function M.Adapter.root(_dir)
  local code, result = process.run({ 'bazel', 'info', 'workspace' }, { stdout = true, stderr = false })
  if code ~= 0 then
    return nil
  end
  local root = vim.trim(result.stdout)
  return vim.trim(root)
end

---Filter directories when searching for test files
---Use bazel query --output=package to find if the directory is a package
---@async
---@param _name string Name of directory
---@param rel_path string Path to directory, relative to root
---@param _root string Root directory of project
---@return boolean
function M.Adapter.filter_dir(_name, rel_path, _root)
  local code, _ = process.run({
    'bazel', 'query',
    '--bes_results_url=', '--bes_backend=',
    '--infer_universe_scope', '--order_output=no',
    '--output=package',
    rel_path
  }, { stdout = false, stderr = false })
  return code == 0
end

---@class Bazel.target
---@field label string
---@field name string

---@class Bazel.file_info
---@field package string
---@field file_target string
---@field test_targets Bazel.target[] | nil

---@async
---@param file_path string
---@return Bazel.file_info
local get_file_info = function(file_path)
  local path = require("plenary.path")
  ---@type string
  local relative_path = path.new(file_path):make_relative(vim.fn.getcwd())

  local file_info = {}

  local _code, result = process.run({
    'bazel', 'query',
    '--bes_results_url=', '--bes_backend=',
    '--infer_universe_scope', '--order_output=no',
    '--output=package',
    relative_path
  }, { stdout = true, stderr = false })
  local bazel_package = vim.trim(result.stdout)
  if bazel_package == '' then
    return file_info
  end
  file_info.package = bazel_package

  _code, result = process.run({
    'bazel', 'query',
    '--bes_results_url=', '--bes_backend=',
    '--infer_universe_scope', '--order_output=no',
    '--output=label',
    relative_path
  }, { stdout = true, stderr = false })
  local label = vim.trim(result.stdout)
  if label == '' then
    return file_info
  end
  file_info.label = label

  local test_query = 'tests(rdeps(' .. bazel_package .. ':all, ' .. label .. ', 1))'
  _code, result = process.run({
    'bazel', 'query',
    '--bes_results_url=', '--bes_backend=',
    '--infer_universe_scope', '--order_output=no',
    test_query
  }, { stdout = true, stderr = false })
  local test_targets = vim.split(vim.trim(result.stdout), '\n')
  file_info.test_targets = {}
  for _, test_target in ipairs(test_targets) do
    table.insert(file_info.test_targets, {
      label = test_target,
      -- Turn '//foo/bar:baz' into 'baz'
      name = test_target:match(":(.*)$"),
    })
  end

  return file_info
end

---@async
---@param file_path string
---@return boolean
function M.Adapter.is_test_file(file_path)
  local file_info = get_file_info(file_path)
  return file_info.test_targets ~= nil and #file_info.test_targets > 0
end

--- Build the tree position from the captured nodes manually
--- so that we could scrub the quotes from the name.
---
--- This was taken from neotest with some modifications
---@param file_path string
---@param source string
---@param captured_nodes table<string, TSNode>
---@return neotest.Position|neotest.Position[]|nil
local function build_position(file_path, source, captured_nodes)
  local match_type = nil
  if captured_nodes["test.name"] then
    match_type = "test"
  elseif captured_nodes["namespace.name"] then
    match_type = "namespace"
  end
  if match_type == nil then
    return nil
  end

  ---@type string
  local name = vim.treesitter.get_node_text(captured_nodes[match_type .. ".name"], source)
  name = name:gsub('"', "") -- Remove quotes
  local definition = captured_nodes[match_type .. ".definition"]
  return {
    type = match_type,
    path = file_path,
    name = name,
    range = { definition:range() },
  }
end

---Given a file path, parse all the tests within it by using different tree-sitter persist_queries
---for different languages based on file extension.
---Currently support: Go, Java
---@async
---@param file_path string Absolute file path
---@return neotest.Tree | nil
function M.Adapter.discover_positions(file_path)
  local treesitter = require("neotest.lib.treesitter")
  local ext = vim.filetype.match({ filename = file_path })
  if ext == "go" then
    local test_func_query = [[
;; query
((function_declaration
  name: (identifier) @test.name) (#match? @test.name "^(Test|Example)"))
  @test.definition
]]
    local subtest_query = [[
;; query
(call_expression
  function: (selector_expression
    field: (field_identifier) @test.method) (#match? @test.method "^Run$")
  arguments: (argument_list . (interpreted_string_literal) @test.name))
  @test.definition
]]
    local test_table_query = [[
;; query
(block
  (short_var_declaration
    left: (expression_list
      (identifier) @test.cases)
    right: (expression_list
      (composite_literal
        (literal_value
          (literal_element
            (literal_value
              (keyed_element
                (literal_element
                  (identifier) @test.field.name)
                (literal_element
                  (interpreted_string_literal) @test.name)))) @test.definition))))
  (for_statement
    (range_clause
      left: (expression_list
        (identifier) @test.case)
      right: (identifier) @test.cases1
        (#eq? @test.cases @test.cases1))
    body: (block
     (expression_statement
      (call_expression
        function: (selector_expression
          field: (field_identifier) @test.method)
          (#match? @test.method "^Run$")
        arguments: (argument_list
          (selector_expression
            operand: (identifier) @test.case1
            (#eq? @test.case @test.case1)
            field: (field_identifier) @test.field.name1
            (#eq? @test.field.name @test.field.name1))))))))
]]
    local list_test_table_wrapped_query = [[
;; query
(for_statement
  (range_clause
      left: (expression_list
        (identifier)
        (identifier) @test.case )
      right: (composite_literal
        type: (slice_type
          element: (struct_type
            (field_declaration_list
              (field_declaration
                name: (field_identifier)
                type: (type_identifier)))))
        body: (literal_value
          (literal_element
            (literal_value
              (keyed_element
                (literal_element
                  (identifier))  @test.field.name
                (literal_element
                  (interpreted_string_literal) @test.name ))
              ) @test.definition)
          )))
    body: (block
      (expression_statement
        (call_expression
          function: (selector_expression
            operand: (identifier)
            field: (field_identifier))
          arguments: (argument_list
            (selector_expression
              operand: (identifier)
              field: (field_identifier) @test.field.name1) (#eq? @test.field.name @test.field.name1))))))
]]
    local test_table_inline_struct_query = [[
;; query
(for_statement
  (range_clause
    right: (composite_literal
      type: (slice_type
        element: (struct_type
          (field_declaration_list
            (field_declaration
              name: (field_identifier) ;; the key of the struct's test name
              type: (type_identifier) @field.type (#eq? @field.type "string")))))
      body: (literal_value
        (literal_element
          (literal_value
            (literal_element
              (interpreted_string_literal) @test.name) @test.definition)))))
  body: (block
    (expression_statement
      (call_expression
        function: (selector_expression
          operand: (identifier)
          field: (field_identifier) @test.method (#match? @test.method "^Run$"))
        arguments: (argument_list
          (selector_expression
            operand: (identifier)
            field: (field_identifier)))))))
]]
    local map_test_table_query = [[
;; query
(block
    (short_var_declaration
      left: (expression_list
        (identifier) @test.cases)
      right: (expression_list
        (composite_literal
          (literal_value
            (keyed_element
            (literal_element
                (interpreted_string_literal)  @test.name)
              (literal_element
                (literal_value)  @test.definition))))))
  (for_statement
     (range_clause
        left: (expression_list
          ((identifier) @test.key.name)
          ((identifier) @test.case))
        right: (identifier) @test.cases1
          (#eq? @test.cases @test.cases1))
      body: (block
         (expression_statement
          (call_expression
            function: (selector_expression
              field: (field_identifier) @test.method)
              (#match? @test.method "^Run$")
              arguments: (argument_list
              ((identifier) @test.key.name1
              (#eq? @test.key.name @test.key.name1))))))))
]]

    local query = test_func_query ..
        subtest_query ..
        test_table_query ..
        list_test_table_wrapped_query ..
        test_table_inline_struct_query ..
        map_test_table_query
    local tree = treesitter.parse_positions(file_path, query, {
      fast = true,
      nested_tests = true,
      build_position = build_position,
    })
    return tree
  elseif ext == "java" then
    local test_class_query = [[
;; query
(class_declaration
  name: (identifier) @namespace.name
) @namespace.definition
]]

    local parameterized_test_query = [[
;; query
(method_declaration
  (modifiers
    (marker_annotation
      name: (identifier) @annotation
        (#any-of? @annotation "Test" "ParameterizedTest" "CartesianTest")
      )
  )
  name: (identifier) @test.name
) @test.definition
]]

    local query = test_class_query .. parameterized_test_query
    return treesitter.parse_positions(file_path, query, {})
  end
end

-- Converts the AST-detected Neotest node test name into the 'go test' command
-- test name format.
---@param pos_id string
---@return string
local id_to_gotest_name = function(pos_id)
  -- construct the test name
  local test_name = pos_id
  -- Remove the path before ::
  test_name = test_name:match("::(.*)$")
  -- Replace :: with /
  test_name = test_name:gsub("::", "/")
  -- Remove double quotes (single quotes are supported)
  test_name = test_name:gsub('"', "")
  -- Replace any spaces with _
  test_name = test_name:gsub(" ", "_")

  return test_name
end

---@class RunspecContext
---@field language string
---@field file_info Bazel.file_info
---@field test_filter string | nil

---@param args neotest.RunArgs
---@return nil | neotest.RunSpec | neotest.RunSpec[]
function M.Adapter.build_spec(args)
  local tree = args.tree
  local pos = tree:data()
  local ext = vim.filetype.match({ filename = pos.path })

  if pos.type == "test" then
    if ext == "go" then
      local test_name = id_to_gotest_name(pos.id)
      local file_info = get_file_info(tree:data().path)

      --- @type RunspecContext
      local context = {
        language = "go",
        file_info = file_info,
        test_filter = test_name,
      }
      local run_specs = {}
      for _, test_target in ipairs(file_info.test_targets) do
        table.insert(run_specs, {
          command = { "bazel", "test", test_target.label, "--test_filter=" .. test_name },
          context = context,
        })
      end
      return run_specs
    end
  elseif pos.type == "file" then
    if ext == "go" then
      local file_info = get_file_info(tree:data().path)

      --- @type RunspecContext
      local context = {
        language = "go",
        file_info = file_info,
      }
      local run_specs = {}
      for _, test_target in ipairs(file_info.test_targets) do
        table.insert(run_specs, {
          command = { "bazel", "test", test_target.label },
          context = context,
        })
      end
      return run_specs
    end
  elseif pos.type == "dir" or pos.type == "namespace" then
    vim.print("Directory or namespace is not supported yet")
    return nil
  end

  return nil
end

---@async
---@param spec neotest.RunSpec
---@param _result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function M.Adapter.results(spec, _result, tree)
  local xml = require('neotest.lib.xml')
  local file = require('neotest.lib.file')

  local _code, result = process.run({ 'bazel', 'info', 'bazel-testlogs' }, { stdout = true, stderr = false })
  local bazel_testlogs = vim.trim(result.stdout)

  ---@type table<string, neotest.Result>
  local neotest_results = {}
  local pos = tree:data()
  if pos.type == "dir" or pos.type == "namespace" then
    vim.print("Directory or namespace is not supported yet")
    return neotest_results
  end

  for _, target_name in ipairs(spec.context.file_info.test_targets) do
    ---@type string
    local test_target_dir = bazel_testlogs .. '/' ..
        spec.context.file_info.package .. '/' ..
        target_name.name

    -- For each Bazel test target, there could be one direct "test.xml" and "test.log" file
    -- or multiple "test.xml" and "test.log" files in subdirectories for sharded tests.
    local xml_files = vim.fs.find("test.xml", {
      path = test_target_dir,
      type = "file",
      limit = math.huge,
    })
    for _, junit_xml in pairs(xml_files) do
      local junit_data = xml.parse(file.read(junit_xml))
      for _, testsuite in pairs(junit_data.testsuites) do
        if testsuite.testcase then
          for _, testcase in pairs(testsuite.testcase) do
            logger.debug("Testcase: " .. vim.inspect(testcase))
            local test_name = ''
            if testcase._attr then
              test_name = testcase._attr.name
            else
              test_name = testcase.name
            end
            test_name = test_name:gsub("/", "::")
            local file_name = vim.split(pos.id, '::')[1]
            test_name = file_name .. '::' .. test_name

            local test_log_dir = vim.fs.dirname(junit_xml)
            if testcase.failure then
              neotest_results[test_name] = {
                status = 'failed',
                output = test_log_dir .. '/' .. 'test.log',
                short = testcase.failure._attr.message,
                errors = {
                  {
                    message = testcase.failure._attr.message,
                    line = pos.range[1],
                  },
                },
              }
            else
              neotest_results[test_name] = {
                status = 'passed',
                output = test_log_dir .. '/' .. 'test.log',
              }
            end
          end
        end
      end
    end
  end

  return neotest_results
end

return M.Adapter
