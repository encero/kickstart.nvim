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

local q                              = vim.treesitter.query
local ts_utils                       = require 'nvim-treesitter.ts_utils'

local TestStatusExecuted             = 'executed'
local TestStatusStale                = 'stale'
local TestStatusNew                  = 'new'
local TestStatusRunning              = 'running'

local state                          = {
	buffers = {},
	tests = {},
}
local go_package_cache               = {}

local all_tests_query                = vim.treesitter.parse_query("go", test_function_query_string_all)
local ns                             = vim.api.nvim_create_namespace "live-tests"

-- copy package info to all matching buffers
local function update_buffers_with_package_info(dir)
	local spec = go_package_cache[dir]

	for _, data in pairs(state.buffers) do
		if vim.fs.dirname(data.file) == dir then
			data.package_data = spec
		end
	end
end

-- read pacakge info from "go list" for given go filename and update any registered buffers after
local function update_package_info_for_file(go_filename, callback)
	local dir = vim.fs.dirname(go_filename)
	if go_package_cache[dir] then
		update_buffers_with_package_info(dir)

		if callback then callback() end
		return
	end

	go_package_cache[dir] = {
		status = "loading"
	}

	vim.fn.jobstart(string.format("go list -json %s", vim.fs.dirname(go_filename)), {
		stdout_buffered = true,
		on_stdout = function(_, data)
			local module = vim.fn.json_decode(data)
			if not module then
				error("can't parse go list output")
			end

			go_package_cache[dir] = {
				status = "loaded",
				import_path = module.ImportPath or "",
				test_files = module.TestGoFiles or {},
				external_test_files = module.XTestGoFiles or {},
			}

			update_buffers_with_package_info(dir)
			if callback then callback() end
		end,
	})
end

local function find_all_tests_in_buffer(go_bufnr)
	local parser = vim.treesitter.get_parser(go_bufnr, "go", {})
	local tree = parser:parse()[1]
	local root = tree:root()

	local tests = {}

	-- iterate over all captures in buffer, from 0 to -1 line ( entire files )
	for id, node in all_tests_query:iter_captures(root, go_bufnr, 0, -1) do
		if node:type() == 'function_declaration' then
			local test_name_node = node:field('name')[1]

			table.insert(tests, {
				name = q.get_node_text(test_name_node, go_bufnr),
				line = ({ test_name_node:range() })[1],
			})
		end
	end

	return tests
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
	end

	return state.tests[test_key]
end

local add_golang_output = function(entry)
	table.insert(state.tests[make_key(entry)].output, vim.trim(entry.Output))
end

local function mark_test_result(entry)
	local test = state.tests[make_key(entry)]

	test.success = entry.Action == "pass"
	test.status = TestStatusExecuted
	test.elapsed = entry.Elapsed
end

local function find_test_in_buffers(test_key)
	for bufnr, data in pairs(state.buffers) do
		for _, buffer_test in ipairs(data.tests) do
			local key = string.format('%s/%s', data.package_data.import_path, buffer_test.name)
			if key == test_key then
				return bufnr, buffer_test
			end
		end
	end
end

local function update_test_marks(test)
	local bufnr, buffer_test = find_test_in_buffers(test.key)

	if not bufnr then
		return
	end

	local text = { '' }

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
			text = { "waiting (pass)", "DiagnosticInfo" }
		else
			text = { 'waiting (fail)', 'DiagnosticInfo' }
		end
	else
		text = { "unknown", 'DiagnosticInfo' }
	end

	if buffer_test.mark then
		vim.api.nvim_buf_del_extmark(bufnr, ns, buffer_test.mark)
	end

	buffer_test.mark = vim.api.nvim_buf_set_extmark(bufnr, ns,
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
		state.buffers[ev.buf].tests = find_all_tests_in_buffer(ev.buf)
	end
})

-- auto execute test on gofile save
vim.api.nvim_create_autocmd("BufWritePost", {
	group = vim.api.nvim_create_augroup(string.format("teej-automagic-%s", bufnr), { clear = true }),
	pattern = "*.go",
	callback = function()
		-- clear all extmarks, highlight, etc
		-- for bufnr, _ in ipairs(state.buffers) do
		-- 	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		-- end

		-- clean test state
		for name, test in pairs(state.tests) do
			test.Output = {}
			test.status = TestStatusStale
			update_test_marks(test)
		end

		local command = { 'go', 'test', './...', '-json' }

		vim.fn.jobstart(command, {
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
					if test.line then
						if not test.success then
							table.insert(failed, {
								bufnr = bufnr,
								lnum = test.line,
								col = 0,
								severity = vim.diagnostic.severity.ERROR,
								source = "go-test",
								message = "Test Failed",
								user_data = {},
							})
						end
					end
				end

				-- vim.diagnostic.set(ns, bufnr, failed, {})
			end,
		})
	end,
})

local function find_test_at_cursor()
	local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(0))

	local package = go_package_cache[dir]
	assert(package, 'no package infor for file')

	local node = ts_utils.get_node_at_cursor()
	if not node then
		return
	end

	while node do
		if node:type() == 'function_declaration' then
			local test_name = vim.treesitter.query.get_node_text(node:child(1), 0)
			local key = string.format('%s/%s', package.import_path, test_name)

			local test = state.tests[key]

			return test
		end

		node = node:parent()
	end
end


-- experimental mapping to find the test the cursor is in
vim.keymap.set('n', '<leader>rt', function()
end, { silent = true })

local function register_test_buffer(ev)
	-- skip already loaded buffers
	if state.buffers[ev.buf] then
		state.buffers[ev.buf].in_window = true
		return
	end

	buf                   = {
		in_window = true,
		file = ev.file,
		tests = find_all_tests_in_buffer(ev.buf),
	}
	state.buffers[ev.buf] = buf

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

	update_package_info_for_file(ev.file, function()
		print("after open", vim.inspect(buf))
		for _, buf_test in ipairs(buf.tests) do
			local key = string.format('%s/%s', buf.package_data.import_path, buf_test.name)
			local test = state.tests[key]

			if test then
				update_test_marks(test)
			end
		end
	end)
end

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
		register_test_buffer(ev)
	end
})
