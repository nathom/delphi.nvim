{
  description = "Dev env for delphi.nvim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system;};
      pluginSrc = self;
    in {
      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          (neovim.override {configure = {};})
          vimPlugins.plenary-nvim
          vimPlugins.telescope-nvim
          vimPlugins.nvim-cmp
          vimPlugins.cmp-path
          git
          curl
          jq
          ripgrep
          lua-language-server
          stylua
        ];

        shellHook = ''
          export NVIM_TEST_HOME=$(mktemp -d)

          # expose paths to Lua
          export DELPHI_PATH=$PWD
          export PLENARY_PATH=${pkgs.vimPlugins.plenary-nvim}

          cat > "$NVIM_TEST_HOME/init.lua" <<'LUA'
            local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
            if not vim.loop.fs_stat(lazypath) then
              vim.fn.system({
                "git", "clone",
                "--filter=blob:none",
                "https://github.com/folke/lazy.nvim.git",
                "--branch=stable", lazypath
              })
            end
            vim.opt.rtp:prepend(lazypath)

            vim.g.mapleader = " "
            require("lazy").setup({
              {
                dir = os.getenv("DELPHI_PATH"),
                name = "delphi.nvim",
                dependencies = { "nvim-lua/plenary.nvim", "nvim-telescope/telescope.nvim", "hrsh7th/nvim-cmp", "hrsh7th/cmp-path"},
                keys = {
                  { "<leader><cr>", "<Plug>(DelphiChatSend)", desc = "Delphi: send chat" },
                  { "<C-i>", "<Plug>(DelphiRewriteSelection)", mode = { "x", "s" }, desc = "Delphi: rewrite selection" },
                  { "<C-i>", "<Plug>(DelphiInsertAtCursor)", mode = { "n", "i" }, desc = "Delphi: insert at cursor" },
                  { "<C-e>", "<Plug>(DelphiExplainSelection)", mode = { "x", "s" }, desc = "Delphi: explain selection" },
                  { "<C-e>", "<Plug>(DelphiExplainAtCursor)", mode = { "n" }, desc = "Delphi: explain at cursor" },
                  { "<leader>a", "<Plug>(DelphiRewriteAccept)", desc = "Delphi: accept rewrite" },
                  { "<leader>R", "<Plug>(DelphiRewriteReject)", desc = "Delphi: reject rewrite" },
                },
                cmd = { "Chat", "Rewrite", "Explain" },
                opts = {
                  allow_env_var_config = true,
                  max_prompt_window_width = 80,
                  chat = { default_model = "gemini_flash", scroll_on_send = true },
                  rewrite = { default_model = "gemini_flash" },
                  models = {
                    gemini_flash = {
                      base_url = "https://openrouter.ai/api/v1", -- SET THIS UP
                      api_key_env_var = "OPENROUTER_API_KEY", -- SET THIS UP
                      model_name = "google/gemini-2.5-flash",
                    }
                  }
                },
              }
            })
          LUA

          alias nvtest='XDG_CONFIG_HOME=$NVIM_TEST_HOME nvim --clean -u "$NVIM_TEST_HOME/init.lua"'
          echo "Type 'nvtest' for an isolated NVim with plenary + your plugin."
        '';
      };
    });
}
