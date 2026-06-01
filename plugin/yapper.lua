-- Loaded automatically during Neovim startup.
-- Ensures the plugin is always loaded (commands, autocmds, keymaps).
-- The actual config is applied by lazy.nvim's opts call to setup(opts).
--
-- Note: config.setup() now handles both the bare call (from plugin/yapper.lua)
-- and the explicit call from lazy: a bare call initialises defaults;
-- a subsequent call with opts by lazy always re-merges the user's config.
require("yapper").setup()
