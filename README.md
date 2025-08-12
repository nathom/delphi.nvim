<h1 align="center">delphi.nvim</h1>

<p align="center">
  <img src="assets/pythia.jpg" alt="Pythia" width="300" style="border: 1px solid #ddd; border-radius: 4px; padding: 2px;">
</p>

<p align="center"><em>Priestess of Delphi</em>, 1891<br>John Collier<br>Oil on canvas</p>


## Features

- Clean and snappy Vim buffer based chat interface
- Local storage for chat history, with [Telescope](https://github.com/nvim-telescope/telescope.nvim) integration
- Code rewrite command with unified diff
- Live streaming of tokens
- Pure Lua OpenAI client and diff algorithm


## Setup 

You'll need a plugin manager (such as [lazy](https://github.com/folke/lazy.nvim)), and an OpenAI compatible
LLM API (such as [OpenRouter](https://openrouter.ai)).

Example configuration with lazy.nvim:

```lua
{
        "nathom/delphi.nvim",
        keys = {
                { "<leader><cr>", "<Plug>(DelphiChatSend)", desc = "Delphi: send chat" },
                { "<leader>r", "<Plug>(DelphiRewriteSelection)", mode = "x", desc = "Delphi: rewrite selection" },
                { "<leader>a", "<Plug>(DelphiRewriteAccept)", desc = "Delphi: accept rewrite" },
                { "<leader>R", "<Plug>(DelphiRewriteReject)", desc = "Delphi: reject rewrite" },
                { "<Esc><Esc>", "<Plug>(DelphiPromptCancel)", mode = { "n", "i" }, desc = "Delphi: cancel prompt" },
        },
        opts = {
                chat = { default_model = "gemini_25" },
                rewrite = { default_model = "kimi_k2" },
                models = {
			gemini_25 = {
				base_url = "https://openrouter.ai/api/v1",
				api_key_env_var = "OPENROUTER_API_KEY",
				model_name = "google/gemini-2.5-pro",
			},
			kimi_k2 = {
				base_url = "https://openrouter.ai/api/v1",
				api_key_env_var = "OPENROUTER_API_KEY",
				model_name = "moonshotai/kimi-k2",
			},
		},
	},
	dependencies = { "nvim-lua/plenary.nvim" },
}
```

In this case, delphi will expect your OpenRouter API keys under the environment variable `OPENROUTER_API_KEY`.

## Usage

### Chat

Type `:Chat` to open up a chat buffer. If one is already open
in your Neovim instance, it will switch to that buffer. If you want to create a new chat regardless, use `:Chat new`.

Example blank chat buffer:


```md
---
model: kimi_k2
temperature: 0.7
---

System:


User:

```

To send a message to the model, type text below `User:`, switch to normal mode, and trigger `<Plug>(DelphiChatSend)`.


```md
---
model: kimi_k2
temperature: 0.7
---

System:


User:
Is it worth switching to Neovim?
```

You should see the model's response being streamed in live.

```md
---
model: kimi_k2
temperature: 0.7
---

System:


User:
Is it worth switching to Neovim?

Assistant:
Short answer  
If you already know Vim and are happy with it, you probably don’t *need* to switch—but if you enjoy experimenting,
want modern features without waiting for Bram to merge them, or are starting from scratch, Neovim is almost always the better choice today.

Below is a practical “decision matrix” so you can decide whether the switch is worth the one-time migration cost for *you*.
...
```

The system prompt can usually be left empty, as the provider will set a reasonable one for you.

#### Chat history

You have two options:

- Use `:Telescope delphi chats`
- Run `:Chat list` to view the ids and titles of chats, and `:Chat go <id>` to open them

### Rewrite

This command allows the LLM to rewrite a selected block of code according
to your instructions. It will display a unified diff, which is updated as
tokens are streamed in.

To use it

- open a buffer with some text
- highlight a few lines in Visual Lines mode (shift-V)
- trigger `<Plug>(DelphiRewriteSelection)`, which should open a popup
- instruct the model, hit `ENTER`
- accept or reject the changes via `<Plug>(DelphiRewriteAccept)` or `<Plug>(DelphiRewriteReject)`

### Configuration

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
---@field rewrite { system_prompt: string, default_model: string?, prompt_template: string }
```

These are the default opts:

````lua
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
        rewrite = {
                default_model = nil,
                system_prompt = [[
You are an expert refactoring assistant. You ALWAYS respond with the rewritten code or text enclosed in <delphi:refactored_code> tags:
<delphi:refactored_code>
...
</delphi:refactored_code>]],
                prompt_template = [[
Full file for context:
<delphi:current_file>
{{file_text}}
</delphi:current_file>

Selected lines ({{selection_start_lnum}}:{{selection_end_lnum}}):
<delphi:selected_lines>
{{selected_text}}
</delphi:selected_lines>

Instruction: {{user_instructions}}. Return ONLY the refactored code inside <delphi:refactored_code> tags. Preserve formatting unless told otherwise. Try to keep the diff minimal while following the instructions exactly.]],
        },
}
```
