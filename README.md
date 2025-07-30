# delphi.nvim

A tasteful LLM plugin. Under construction.

## Configuration

These are the schema:

```lua
---@class Model
---@field base_url string
---@field api_key_env_var string
---@field model_name string
---@field temperature number

---@class Config
---@field models table<string, Model>
---@field allow_env_var_config boolean
---@field chat { system_prompt: string, default_model: string?, headers: { system: string, user: string, assistant: string } }
---@field refactor { system_prompt: string, default_model: string?, prompt_template: string, accept_keymap: string, reject_keymap: string }
```

These are the default opts:

```lua
opts = {
	models = {},
	allow_env_var_config = false,
	chat = {
		system_prompt = "",
		default_model = nil,
		headers = {
			system = "System:",
			user = "User:",
			assistant = "Assistant:",
		},
	},
	refactor = {
		default_model = nil,
		system_prompt = [[
You are an expert refactoring assistant. Return ONLY the rewritten code in one fenced block:
\```
...
```.]],
		prompt_template = [[
Full file for context:
\```
{{file_text}}
\```

Selected lines ({{selection_start_lnum}}:{{selection_end_lnum}}):
\```
{{selected_text}}
\```

Instruction: {{user_instructions}}. Return ONLY the refactored code within a code block. Preserve formatting unless told otherwise. Try to keep the diff minimal while following the instructions exactly.]],
		accept_keymap = "<leader>a",
		reject_keymap = "<leader>r",
	},
}
```

## File tagging
Delphi supports using `@path/to/file` in chat messages. The request sent to the language model will include a `<tagged_files>` block with the file contents. Snapshots are stored alongside each chat in `chat_n_meta.json`.
