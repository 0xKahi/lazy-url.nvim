---@class LazyUrl.Config
---@field browsers (string[] | table<string, LazyUrl.Browser>) list of preset names (string array) or map of name to override
---@field custom LazyUrl.CustomList ordered list of pattern→handler entries
---@field default_browser? string if set, must be a name present in browsers

---@class LazyUrl.Browser
---@field cmd? string | string[] override the preset command
---@field args? string[] arguments passed before the URL

---@class LazyUrl.CustomEntry
---@field pattern string Lua pattern (NOT PCRE) matched against the full URL
---@field handler fun(url: string): LazyUrl.Command transform url to command spec (args already include url)

---@alias LazyUrl.CustomList LazyUrl.CustomEntry[]

---@class LazyUrl.Command
---@field cmd string executable name
---@field args? string[] arguments (handler is responsible for including the transformed URL)

local M = {}

---Browser presets: per-OS command specs. OS detection happens in open.lua.
---The 'default' entry is a sentinel — open.lua routes it to vim.ui.open().
M.presets = {
  default = { default = true },
  brave = {
    mac = { cmd = 'open', args = { '-a', 'Brave Browser' } },
    linux = { cmd = 'brave-browser', args = {} },
    windows = { cmd = 'cmd.exe', args = { '/c', 'start', 'brave' } },
  },
  firefox = {
    mac = { cmd = 'open', args = { '-a', 'Firefox' } },
    linux = { cmd = 'firefox', args = {} },
    windows = { cmd = 'cmd.exe', args = { '/c', 'start', 'firefox' } },
  },
  chrome = {
    mac = { cmd = 'open', args = { '-a', 'Google Chrome' } },
    linux = { cmd = 'google-chrome', args = {} },
    windows = { cmd = 'cmd.exe', args = { '/c', 'start', 'chrome' } },
  },
  safari = {
    mac = { cmd = 'open', args = { '-a', 'Safari' } },
  },
  arc = {
    mac = { cmd = 'open', args = { '-a', 'Arc' } },
  },
  zen = {
    mac = { cmd = 'open', args = { '-a', 'Zen Browser' } },
    linux = { cmd = 'zen-browser', args = {} },
    windows = { cmd = 'cmd.exe', args = { '/c', 'start', 'zen' } },
  },
  edge = {
    mac = { cmd = 'open', args = { '-a', 'Microsoft Edge' } },
    linux = { cmd = 'microsoft-edge', args = {} },
    windows = { cmd = 'cmd.exe', args = { '/c', 'start', 'msedge' } },
  },
}

---Default configuration applied before user opts.
---@type LazyUrl.Config
M.defaults = {
  browsers = { 'default' },
  custom = {},
  default_browser = nil,
}

---Merge user opts with defaults. Arrays at the same key REPLACE (not concat).
---@param opts? LazyUrl.Config
---@return LazyUrl.Config
function M.merge(opts)
  opts = opts or {}
  assert(type(opts) == 'table', 'lazy-url: opts must be a table')
  return vim.tbl_deep_extend('force', {}, M.defaults, opts)
end

---Validate merged config. Throws on invalid input.
---@param config LazyUrl.Config
function M.validate(config)
  if config.default_browser ~= nil then
    local found = false
    if type(config.browsers) == 'table' then
      for _, b in ipairs(config.browsers) do
        if b == config.default_browser then
          found = true
          break
        end
      end
    end
    if not found then
      error(string.format("lazy-url: default_browser '%s' is not in the browsers list", config.default_browser))
    end
  end
  for i, entry in ipairs(config.custom) do
    assert(type(entry.pattern) == 'string', string.format('lazy-url: custom[%d].pattern must be a string', i))
    assert(type(entry.handler) == 'function', string.format('lazy-url: custom[%d].handler must be a function', i))
  end
end

return M
