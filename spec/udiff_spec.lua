-- Make local module path discoverable
package.path = table.concat({
	"./lua/?.lua",
	"./lua/?/init.lua",
	package.path,
}, ";")

local U = require("delphi.udiff").new

describe("delphi.udiff", function()
	it("applies partial and full hunks incrementally", function()
		local base = { "a", "b", "c" }
		local p = U(base)

		-- partial stream (header + deletion only)
		p:push("@@ -2,1 +2,2 @@\n-b\n")
		local partial = p:apply_partial()
		assert.are.same({ "a", "c" }, partial)

		-- remainder stream (additions)
		p:push("+beta\n+new\n")
		local full = p:apply_partial()
		assert.are.same({ "a", "beta", "new", "c" }, full)
	end)

	it("produces overlay ops with correct anchors", function()
		local base = { "a", "b", "c" }
		local p = U(base)
		p:push("@@ -2,1 +2,2 @@\n-b\n+beta\n+new\n")
		p:apply_partial()

		local ops = p:overlay_ops()
		local dels, adds = 0, 0
		for _, op in ipairs(ops) do
			if op.kind == "del" then
				dels = dels + 1
				assert.equals(1, op.row)
				assert.equals("b", op.text)
			elseif op.kind == "add" then
				adds = adds + 1
				-- additions anchor at next base row; virt_lines_above renders before it
				assert.equals(2, op.row)
			end
		end
		assert.equals(1, dels)
		assert.equals(2, adds)
	end)

	it("parses multiple hunks across the file", function()
		local base = { "h1", "x", "y", "h2", "p", "q", "h3" }
		local p = U(base)
		p:push(table.concat({
			"@@ -2,2 +2,2 @@",
			"-x",
			"-y",
			"+X",
			"+Y",
			"@@ -5,1 +5,2 @@",
			" p",
			"+P2",
			" q",
		}, "\n") .. "\n")
		local out = p:apply_partial()
		assert.are.same({ "h1", "X", "Y", "h2", "p", "P2", "q", "h3" }, out)
	end)

	it("ignores non-hunk headers and tolerates trailing text", function()
		local base = { "a", "b" }
		local p = U(base)
		p:push(table.concat({
			"diff --git a/file b/file",
			"index 000..111 100644",
			"--- a/file",
			"+++ b/file",
			"@@ -1,2 +1,2 @@",
			" a",
			"-b",
			"+B",
			"trailer text that should be ignored",
		}, "\n"))
		local out = p:apply_partial()
		assert.are.same({ "a", "B" }, out)
		local ops = p:overlay_ops()
		assert.is_true(#ops >= 1)
	end)
end)
