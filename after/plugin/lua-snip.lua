local ls = require 'luasnip'

local s = ls.snippet
local i = ls.insert_node
local c = ls.choice_node
local t = ls.text_node

local fmt = require("luasnip.extras.fmt").fmt

ls.add_snippets("lua", {
	s("pi", fmt("print(vim.inspect({}))", i(0))),
	s("v", fmt("local {} = {}", { i(1), i(0) })),
	s("cv", fmt("local {} <const> = {}", { i(1), i(0) })),
})
