# delphi.nvim

A tasteful LLM plugin.

WIP.

## Configuration

Chat headers are customizable via the `chat.headers` option:

```lua
require("delphi").setup({
  chat = {
    headers = {
      system = "SYS>",
      user = "ME>",
      assistant = "BOT>",
    },
  },
})
```
