local M = {}
local uv = vim.uv or vim.loop

-- Some tasteful frame sets (add your own if you like)
local FRAME_SETS = {
	dots = { "⠁", "⠂", "⠄", "⠂" },
	dots2 = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
	line = { "─", "\\", "│", "/" },
	bounce = { "⠂", "⠄", "⠂", "⠄" },
	arc = { "◜", "◠", "◝", "◞", "◡", "◟" },
}

local DEFAULTS = {
	bufnr = nil, -- defaults to current buffer at start()
	row = 0, -- 0-based extmark row
	col = 0, -- 0-based extmark col (ignored for right_align/eol)
	frames = "dots2", -- name in FRAME_SETS or array of strings
	interval = 80, -- ms between frames
	label = nil, -- extra text after spinner, e.g. "Loading"
	virt_text_pos = "eol", -- "eol" | "right_align" | "overlay" | "inline"
	hl = "Comment", -- highlight group for spinner/label
	namespace = "DelphiSpinner",
	autohide_on_stop = true, -- clear extmark on stop
}

---@class Spinner
---@field opts table Full configuration options
---@field _timer? uv_timer_t libuv timer handle
---@field _ns integer nvim_create_namespace handle
---@field _mark? integer extmark id
---@field _i integer Current frame index
---@field _running boolean Running state flag
local Spinner = {}
Spinner.__index = Spinner

local function normalize_frames(frames)
	if type(frames) == "string" then
		return FRAME_SETS[frames] or FRAME_SETS.dots2
	end
	return frames or FRAME_SETS.dots2
end
---@class DelphiSpinnerOpts
---@field bufnr? integer  defaults to current buffer at `start()`
---@field row? integer    0-based extmark row (default 0)
---@field col? integer    0-based extmark col (ignored for right_align/eol)
---@field frames? string|string[]  name in `FRAME_SETS` or an array of frame strings
---@field interval? integer  ms between frames (default 80)
---@field label? string      extra text after spinner, e.g. "Loading"
---@field virt_text_pos? "eol"|"right_align"|"overlay"|"inline"  (default "eol")
---@field hl? string         highlight group for spinner/label (default "Comment")
---@field namespace? string  extmark namespace name (default "DelphiSpinner")
---@field autohide_on_stop? boolean  clear extmark on stop (default true)

---Create a new animated extmark spinner
---@param opts? DelphiSpinnerOpts
---@return Spinner
function Spinner.new(opts)
	opts = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), opts or {})
	opts.frames = normalize_frames(opts.frames)
	local self = setmetatable({
		opts = opts,
		_timer = nil,
		_ns = vim.api.nvim_create_namespace(opts.namespace),
		_mark = nil,
		_i = 1,
		_running = false,
	}, Spinner)
	return self
end

function Spinner:_place_mark()
	local o = self.opts
	local bufnr = o.bufnr or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	-- compose virt_text each tick; initial placeholder now
	local text = o.frames[self._i]
	if o.label and #o.label > 0 then
		text = text .. " " .. o.label
	end
	local id = self._mark or 0
	self._mark = vim.api.nvim_buf_set_extmark(bufnr, self._ns, o.row, o.col, {
		id = id ~= 0 and id or nil,
		virt_text = { { text, o.hl } },
		virt_text_pos = o.virt_text_pos, -- eol/right_align/etc.
		hl_mode = "combine",
		strict = false,
	})
end

function Spinner:_tick()
	local o = self.opts
	local bufnr = o.bufnr or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(bufnr) then
		self:stop()
		return
	end
	self._i = (self._i % #o.frames) + 1
	local text = o.frames[self._i]
	if o.label and #o.label > 0 then
		text = text .. (" " .. o.label)
	end -- string concat
	-- update virt_text in-place
	if self._mark then
		vim.api.nvim_buf_set_extmark(bufnr, self._ns, o.row, o.col, {
			id = self._mark,
			virt_text = { { text, o.hl } },
			virt_text_pos = o.virt_text_pos,
			hl_mode = "combine",
			strict = false,
		})
	else
		self:_place_mark()
	end
end

function Spinner:start()
	if self._running then
		return self
	end
	self._running = true
	self:_place_mark()
	self._timer = uv.new_timer()
	self._timer:start(self.opts.interval, self.opts.interval, function()
		-- do UI ops on main thread
		vim.schedule(function()
			if self._running then
				self:_tick()
			end
		end)
	end)
	return self
end

function Spinner:stop()
	if not self._running then
		return self
	end
	self._running = false
	if self._timer and not self._timer:is_closing() then
		self._timer:stop()
		self._timer:close()
	end
	self._timer = nil
	vim.api.nvim_buf_del_extmark(self.opts.bufnr, self._ns, self._mark)
	self._mark = nil
	return self
end

function Spinner:set_label(label)
	self.opts.label = label
	-- force immediate redraw
	if self._running then
		self:_tick()
	else
		self:_place_mark()
	end
end

function Spinner:set_frames(frames)
	self.opts.frames = normalize_frames(frames)
	self._i = 1
end

function Spinner:attach(bufnr, row, col)
	self.opts.bufnr, self.opts.row, self.opts.col = bufnr, row or 0, col or 0
	if self._running then
		self:_place_mark()
	end
	return self
end

M.new = Spinner.new
return M
