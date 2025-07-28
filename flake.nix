{
  description = "Dev env for delphi.nvim";

  inputs = {
    nixpkgs.url      = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url  = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
  flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs { inherit system; };
      pluginSrc  = self;
    in
    {
      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          (neovim.override { configure = { }; })  # vanilla NVim
          vimPlugins.plenary-nvim                # plenary as a nix pkg
          git curl jq ripgrep lua-language-server stylua
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

            vim.g.mapleader = ' '
            require("lazy").setup({
              {
                dir = os.getenv("DELPHI_PATH"),
                name = "delphi.nvim",
                dependencies = { "nvim-lua/plenary.nvim" },
                opts = {
                  chat = { system_prompt = "You are a helpful assistant.", default_model = "gpt_4o" },
                  refactor = { default_model = "gpt_4o" },
                  models = {
                    gpt_4o = {
                      base_url = "", -- SET THIS UP
                      api_key_env_var = "", -- SET THIS UP
                      model_name = "gpt-4o",
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
