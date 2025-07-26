{
  description = "Dev + test env for myllm.nvim";

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
          export MYLLM_PATH=$PWD
          export PLENARY_PATH=${pkgs.vimPlugins.plenary-nvim}

          cat > "$NVIM_TEST_HOME/init.lua" <<'LUA'
            -- bootstrap lazy.nvim ------------------------------------------------
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

            -- install test-time plugins -----------------------------------------
            require("lazy").setup({
              { dir = os.getenv("MYLLM_PATH"),  name = "myllm.nvim",
                dependencies = { "nvim-lua/plenary.nvim" } },
              "nvim-lua/plenary.nvim",
            })
          LUA

          alias nvtest='XDG_CONFIG_HOME=$NVIM_TEST_HOME nvim --clean -u "$NVIM_TEST_HOME/init.lua"'
          echo "Type 'nvtest' for an isolated NVim with plenary + your plugin."
        '';
      };
    });
}
