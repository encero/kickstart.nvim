local ls = require 'luasnip'

local s = ls.snippet
local i = ls.insert_node

local fmt = require("luasnip.extras.fmt").fmt


ls.add_snippets("go", {
	s('tf', fmt([[func Test{}(t *testing.T) {{\n\t{}\n}}]], { i(1), i(0) })),
	s('met', fmt("func ({}){}({}) {{\n\t{}\n}}", { i(1), i(2), i(3), i(0) })),
})
