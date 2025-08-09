-- Ensure local module path is discoverable in Neovim tests
package.path = table.concat({ "./lua/?.lua", "./lua/?/init.lua", package.path }, ";")

local P = require("delphi.primitives")

-- Small helper to create a scratch buffer, set lines, run fn, then clean up
---@param lines string[]
---@param fn fun(buf: integer)
local function with_buf(lines, fn)
	local buf = vim.api.nvim_create_buf(false, true)
	assert.is_true(vim.api.nvim_buf_is_valid(buf))
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	fn(buf)
	vim.api.nvim_buf_delete(buf, { force = true })
end

describe("full-stack udiff application", function()
	it("positions extmarks to visually overwrite/insert correctly", function()
		local base = { "a", '  print("hello")', "c" }
		with_buf(base, function(buf)
			local preview = P.start_udiff_preview(buf, base)
			-- Replace the middle line with two lines (one indented), ensure anchors
			preview.push('@@ -2,1 +2,2 @@\n-   print("hello")\n+   print("goodbye")\n+ print("again")\n')

			-- Trigger render
			preview.push("")

			local ns = vim.api.nvim_get_namespaces().delphi_ghost_diff
			assert.is_truthy(ns)
			local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })

			local has_del_at_1 = false
			local add_anchor_rows = {}
			for _, m in ipairs(marks) do
				local row = m[2]
				local details = m[4]
				if details and details.virt_text then
					if row == 1 then
						has_del_at_1 = true
					end
				end
				if details and details.virt_lines then
					table.insert(add_anchor_rows, row)
				end
			end

			assert.is_true(has_del_at_1)
			-- Additions should render above the next base row (2)
			local has_add_above_2 = false
			for _, r in ipairs(add_anchor_rows) do
				if r == 2 then
					has_add_above_2 = true
				end
			end
			assert.is_true(has_add_above_2)
		end)
	end)
	it("applies a single hunk and accepts into buffer", function()
		local base = { "a", "b", "c" }
		with_buf(base, function(buf)
			local preview = P.start_udiff_preview(buf, base)
			preview.push("@@ -2,1 +2,2 @@\n-b\n+beta\n+new\n")
			preview.accept()
			local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			assert.are.same({ "a", "beta", "new", "c" }, got)
		end)
	end)

	it("supports multiple hunks across file", function()
		local base = { "h1", "x", "y", "h2", "p", "q", "h3" }
		with_buf(base, function(buf)
			local preview = P.start_udiff_preview(buf, base)
			local diff = table.concat({
				"@@ -2,2 +2,2 @@",
				"-x",
				"-y",
				"+X",
				"+Y",
				"@@ -5,1 +5,2 @@",
				" p",
				"+P2",
				" q",
				"",
			}, "\n")
			preview.push(diff)
			preview.accept()
			local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			assert.are.same({ "h1", "X", "Y", "h2", "p", "P2", "q", "h3" }, got)
		end)
	end)

	it("ignores diff headers and trailing text then applies", function()
		local base = { "a", "b" }
		with_buf(base, function(buf)
			local preview = P.start_udiff_preview(buf, base)
			local diff = table.concat({
				"diff --git a/file b/file",
				"index 000..111 100644",
				"--- a/file",
				"+++ b/file",
				"@@ -1,2 +1,2 @@",
				" a",
				"-b",
				"+B",
				"some trailer text",
				"",
			}, "\n")
			preview.push(diff)
			preview.accept()
			local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			assert.are.same({ "a", "B" }, got)
		end)
	end)

	it("reject leaves buffer unchanged", function()
		local base = { "foo", "bar", "baz" }
		with_buf(base, function(buf)
			local preview = P.start_udiff_preview(buf, base)
			preview.push("@@ -2,1 +2,1 @@\n-bar\n+BAR\n")
			preview.reject()
			local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			assert.are.same(base, got)
		end)
	end)
end)
