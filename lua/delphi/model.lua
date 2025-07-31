---@class Model
---@field base_url string
---@field api_key_env_var string
---@field model_name string
---@field temperature number
-- Define the Model class
local Model = {}
Model.__index = Model

-- Constructor for the Model class
---@param opts { base_url: string, api_key_env_var: string, model_name: string, temperature: number? }
---@return Model
function Model.new(opts)
	local instance = setmetatable({}, Model)

	if not opts.base_url or opts.base_url == "" then
		vim.notify("delphi: model: base_url is required", vim.log.levels.ERROR)
	end
	if not opts.api_key_env_var or opts.api_key_env_var == "" then
		vim.notify("delphi: model: api_key_env_var is required", vim.log.levels.ERROR)
	end
	if not opts.model_name or opts.model_name == "" then
		vim.notify("delphi: model: model_name is required", vim.log.levels.ERROR)
	end

	instance.base_url = opts.base_url
	instance.api_key_env_var = opts.api_key_env_var
	instance.model_name = opts.model_name
	instance.temperature = opts.temperature or 0.7

	return instance
end

---Method to retrieve the API key from the environment variable
---@return string
function Model:get_api_key()
	if self.api_key_env_var == nil then
		vim.notify("delphi: API key env var not provided", vim.log.levels.ERROR)
		return ""
	end

	local ret = os.getenv(self.api_key_env_var)
	if ret == nil or ret == "" then
		vim.notify("delphi: Couldn't find API key under env var " .. self.api_key_env_var, vim.log.levels.ERROR)
		return ""
	end
	return ret
end

local M = {}
M.Model = Model
return M
