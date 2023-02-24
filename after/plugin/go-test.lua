local test_function_query_string_all = [[
(
 (function_declaration
  name: (identifier)
  parameters:
    (parameter_list
     (parameter_declaration
      name: (identifier)
      type: (pointer_type
          (qualified_type
           package: (package_identifier) @_package_name
           name: (type_identifier) @_type_name)))))

 (#eq? @_package_name "testing")
 (#eq? @_type_name "T")
) @test
]]

GT_DEBUG = false
local function db(...)
	if GT_DEBUG then
		print(...)
	end
end

local q                  = vim.treesitter.query
local ts_utils           = require 'nvim-treesitter.ts_utils'

local TestStatusExecuted = 'executed'
local TestStatusStale    = 'stale'
local TestStatusRunning  = 'running'

local test_all_command   = { 'go', 'test', './...', '-json' }
local test_command       = test_all_command

local state              = {
	auto_run = false,
	buffers = {},
	tests = {},
}
local go_package_cache   = {}

local all_tests_query    = vim.treesitter.parse_query("go", test_function_query_string_all)
local ns                 = vim.api.nvim_create_namespace "live-tests"

local function un_ansi(text)
	return text:gsub('\x1b%[%d+;%d+;%d+;%d+;%d+m', '')
	    :gsub('\x1b%[%d+;%d+;%d+;%d+m', '')
	    :gsub('\x1b%[%d+;%d+;%d+m', '')
	    :gsub('\x1b%[%d+;%d+m', '')
	    :gsub('\x1b%[%d+m', '')
end

local function package_for_buffer(buffer, callback)
	local dir = vim.fs.dirname(buffer.file)
	if go_package_cache[dir] then
		if callback then callback(go_package_cache[dir]) end
		return
	end

	vim.fn.jobstart(string.format("go list -json %s", dir), {
		stdout_buffered = true,
		on_stdout = function(_, data)
			local module = vim.fn.json_decode(data)
			if not module then
				error("can't parse go list output")
			end

			go_package_cache[dir] = {
				import_path = module.ImportPath or "",
				test_files = module.TestGoFiles or {},
				external_test_files = module.XTestGoFiles or {},
			}

			if callback then callback(go_package_cache[dir]) end
		end,
	})
end

local function parse_buffer_and_find_all_tests(buffer, callback)
	db("parse_buffer_and_find_all_tests buf:", buffer.bufnr)
	local parser = vim.treesitter.get_parser(buffer.bufnr, "go", {})
	local tree = parser:parse()[1]
	local root = tree:root()

	local tests = {}

	package_for_buffer(buffer, function(package)
		local cnt = 0

		-- iterate over all captures in buffer, from 0 to -1 line ( entire files )
		for _, node in all_tests_query:iter_captures(root, buffer.bufnr, 0, -1) do
			if node:type() == 'function_declaration' then
				local test_name_node = node:field('name')[1]
				local name = q.get_node_text(test_name_node, buffer.bufnr)
				local key = string.format('%s/%s', package.import_path, name)

				tests[key] = {
					key = key,
					package = package.import_path,
					name = name,
					line = ({ test_name_node:range() })[1],
				}

				cnt = cnt + 1
			end
		end

		db("parse_buffer_and_find_all_tests found:", cnt, "tests")
		if callback then callback(tests) end
	end)
end

local function make_key(entry)
	assert(entry.Package, "Must have Package:" .. vim.inspect(entry))
	assert(entry.Test, "Must have Test:" .. vim.inspect(entry))
	return string.format("%s/%s", entry.Package, entry.Test)
end

local function add_golang_test(entry)
	local test_key = make_key(entry)
	local test = state.tests[test_key]
	if not test then
		state.tests[test_key] = {
			key = make_key(entry),
			name = entry.Test,
			package = entry.Package,
			status = TestStatusRunning,
			output = {},
		}
	else
		test.status = TestStatusRunning
		test.output = {}
	end

	return state.tests[test_key]
end

local function add_golang_output(entry)
	local text = un_ansi(vim.trim(entry.Output))

	table.insert(state.tests[make_key(entry)].output, text)
end

local function mark_test_result(entry)
	local test = state.tests[make_key(entry)]

	test.status = TestStatusExecuted
	test.success = entry.Action == "pass"
	test.elapsed = entry.Elapsed
end

local function find_buffer_with_test(test)
	for _, buffer in pairs(state.buffers) do
		if buffer.tests[test.key] then
			return buffer
		end
	end
end

local function update_test_marks(test)
	db("update_test_marks", test.name)
	local buffer = find_buffer_with_test(test)
	if not buffer then
		return
	end

	if not buffer.in_window then
		return
	end

	local buffer_test = buffer.tests[test.key]
	assert(buffer_test, "Buffer doesn't has this test")

	local text = nil

	if test.status == TestStatusExecuted then
		if test.success then
			text = { "🟢 " .. test.elapsed .. "s", "DiagnosticOk" }
		else
			text = { '🔥 ' .. test.elapsed .. "s", 'DiagnosticError' }
		end
	elseif test.status == TestStatusRunning then
		text = { "▶️ ", 'DiagnosticInfo' }
	elseif test.status == TestStatusStale then
		if test.success then
			text = { "stale (pass)", "DiagnosticInfo" }
		else
			text = { 'stale (fail)', 'DiagnosticInfo' }
		end
	else
		text = { "unknown", 'DiagnosticInfo' }
	end

	if buffer_test.mark then
		vim.api.nvim_buf_del_extmark(buffer.bufnr, ns, buffer_test.mark)
	end

	buffer_test.mark = vim.api.nvim_buf_set_extmark(buffer.bufnr, ns,
		buffer_test.line, 0, {
		virt_text = { text },
	})
end

local function handle_test_line(decoded)
	if not decoded.Test then
		return -- not a test result
	end

	local test_key = make_key(decoded)
	local test     = state.tests[test_key]

	if decoded.Action == "run" then
		test = add_golang_test(decoded)
		update_test_marks(test)
	elseif decoded.Action == "output" then
		if not decoded.Test then
			return
		end

		add_golang_output(decoded)
	elseif decoded.Action == "pass" or decoded.Action == "fail" then
		mark_test_result(decoded)
		update_test_marks(test)
	elseif decoded.Action == "pause" or decoded.Action == "cont" then
		-- Do nothing
	else
		error("Failed to handle" .. vim.inspect(decoded))
	end
end

local function parse_test_line(line)
	if line == '' then
		return
	end
	local ok, decoded = pcall(vim.json.decode, line)
	if ok then
		handle_test_line(decoded)
	else
		print("cant parse line:" .. vim.inspect(line) .. " with error:" .. decoded)
	end
end

vim.api.nvim_create_autocmd("BufWritePost", {
	group = vim.api.nvim_create_augroup(string.format("teej-automagic-%s", bufnr), { clear = true }),
	pattern = "*_test.go",
	callback = function(ev)
		local buf = state.buffers[ev.buf]
		parse_buffer_and_find_all_tests(buf, function(tests)
			for _, new_test in pairs(tests) do
				for _, old_test in pairs(buf.tests) do
					if old_test.name == new_test.name then
						new_test.mark = old_test.mark
					end
				end
			end

			buf.tests = tests
		end)
	end
})

local function execute_tests()
	if not state.auto_run then
		return
	end

	-- clean test state
	for _, test in pairs(state.tests) do
		test.Output = {}
		test.status = TestStatusStale
		update_test_marks(test)
	end

	vim.fn.jobstart(test_command, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			if not data then
				return
			end

			for _, line in ipairs(data) do
				parse_test_line(line)
			end
		end,
		on_exit = function()
			local failed = {}
			for _, test in pairs(state.tests) do
				if not test.success then
					local buffer = find_buffer_with_test(test)

					if buffer then
						if not failed[buffer.bufnr] then
							failed[buffer.bufnr] = {}
						end

						table.insert(failed[buffer.bufnr], {
							bufnr = bufnr,
							lnum = buffer.tests[test.key].line,
							col = 0,
							severity = vim.diagnostic.severity.ERROR,
							source = "go-test",
							message = "Test Failed: " .. (test.output[2] or ""),
							user_data = {},
						})
					end
				end
			end

			for bufnr, fails in pairs(failed) do
				vim.diagnostic.set(ns, bufnr, fails, {})
			end
		end,
	})
end

-- auto execute test on gofile save
vim.api.nvim_create_autocmd("BufWritePost", {
	group = vim.api.nvim_create_augroup('encero-go-auto-test', {}),
	pattern = "*.go",
	callback = function()
		execute_tests()
	end,
})
local function find_test_name_at_cursor()
	local node = ts_utils.get_node_at_cursor()
	if not node then
		print("no treesitter node at location")
		return
	end

	while node do
		if node:type() == 'function_declaration' then
			return vim.treesitter.query.get_node_text(node:child(1), 0)
		end

		node = node:parent()
	end
end
local function find_test_at_cursor()
	local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(0))

	local package = go_package_cache[dir]
	assert(package, 'no package info for file')

	local test_name = find_test_name_at_cursor()
	return state.tests[string.format('%s/%s', package.import_path, test_name)]
end

local function update_buffer_remarks(buf)
	db("update_buffer_remarks buf", buf.bufnr)
	for _, buf_test in pairs(buf.tests) do
		local test = state.tests[buf_test.key]

		if test then
			update_test_marks(test)
		end
	end
end

local function buffer_has_entered_window(ev)
	db("buffer_has_entered_window buf:", ev.buf)
	-- skip already loaded buffers
	if state.buffers[ev.buf] then
		local buf = state.buffers[ev.buf]

		buf.in_window = true
		update_buffer_remarks(buf)
		return
	end

	local buf = {
		bufnr = ev.buf,
		in_window = true,
		file = ev.file,
	}

	parse_buffer_and_find_all_tests(buf, function(tests)
		buf.tests             = tests
		state.buffers[ev.buf] = buf

		update_buffer_remarks(buf)
	end)


	-- print test output of test the cursor is at to new vsplit
	vim.api.nvim_buf_create_user_command(ev.buf, "GoTestLineDiag", function()
		local test = find_test_at_cursor()

		if not test then
			print("this test was not runned before")
			return
		end

		vim.cmd.vnew() -- new vertical split
		vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false,
			test.output) -- print test output
	end, {})
end

--[[
        COMMANDS
--]]
--
vim.api.nvim_create_user_command('GTDebug', function()
	local ui = vim.api.nvim_list_uis()[1]

	local data = 'workspace_state:' .. vim.inspect(state) .. '\n'
	data = data .. 'go_package_cache: ' .. vim.inspect(go_package_cache)


	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(data, '\n'))
	local winid = vim.api.nvim_open_win(buf, true, {
		relative = 'editor',
		width = math.floor(ui.width * 0.8),
		height = math.floor(ui.height * 0.8),
		row = math.floor(ui.height * 0.1),
		col = math.floor(ui.width * 0.1),
		border = 'single',
	})

	-- TODO: close when leaving the window

	vim.keymap.set('n', 'q', function()
		vim.api.nvim_win_close(winid, true)
		vim.api.nvim_buf_delete(buf, {})
	end, { buffer = buf, silent = true })
end, {})

--[[ 	
        AUTO CMDS
--]]
-- set buffer as not visible in window, those are not updated with marks
vim.api.nvim_create_autocmd({ "BufWinLeave" }, {
	pattern = '*_test.go',
	callback = function(ev)
		state.buffers[ev.buf].in_window = false
	end
})

-- attach Autotest command to buffers with go tests
vim.api.nvim_create_autocmd({ "BufWinEnter" }, {
	pattern = "*_test.go",
	callback = function(ev)
		buffer_has_entered_window(ev)
	end
})

--[[
-- KEYMAPS
--]]
vim.keymap.set('n', ',ta', function()
	state.auto_run = true
	test_command = test_all_command

	execute_tests()
end, { desc = '[T]est [A]ll' })

vim.keymap.set('n', ',to', function()
	local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(0))

	local test_name = find_test_name_at_cursor()
	assert(test_name, 'No test found')

	state.auto_run = true
	test_command = { 'go', 'test', dir, '-json', '-run', string.format('^%s$', test_name) }

	execute_tests()
end, { desc = '[T]est [O]ne' })
-- DEBUG
-- state.auto_run = true
