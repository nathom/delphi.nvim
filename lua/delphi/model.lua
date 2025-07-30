---@class Model
---@field base_url string
---@field api_key_env_var string
---@field model_name string
---@field temperature number
-- Define the Model class
local Model = {}
Model.__index = Model

-- Constructor for the Model class
---@param opts { base_url: string, api_key_env_var: string, model_name: string, temperature: number }
---@return Model
function Model.new(opts)
	local instance = setmetatable({}, Model)
	for k, v in pairs(opts) do
		instance[k] = v
	end
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
