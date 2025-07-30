# development guidelines

The testing environment is defined in `flake.nix`. Your environment has nix installed, so run everything using it. You may use the nvtest (a nvim alias) program headless to test scripts.

## general 

- when using a vim api, ALWAYS look up the helpdocs and read through it to make sure it's correct
- if you want the docs for a specific vim plugin, you can use nix to install it if needed and read the help docs afterward
- update `flake.nix` to include new dependencies if necessary. ensure the configuration in `flake.nix` is up-to-date
- do not update the README unless explicitly requested
- any functions that interact with the vim editor api MUST have a wrapper in primitives.lua. this is so that i can go in and fix things easily if an api call is wrong. choose the api and scope of your new functions wisely. keep things modular and clean.

## style

- every function and class needs to have type annotations
- write code as if lua was strictly typed
- use stylua for formatting

## testing

to test code, create temporary lua test scripts (do not check them in!) to test sections of your code. you may use nvtest headless for execution if you're using vim apis.
