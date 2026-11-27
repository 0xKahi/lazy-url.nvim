---@class LazyUrl
---@field config LazyUrl.Config
---@field setup fun(opts?: LazyUrl.Config)
---@field smart_open fun(): boolean
---@field open fun(url: string): boolean
---@field rex { reset: fun() } Rex routing; `LazyUrl.rex.reset()` clears cached host discovery
local M = {}

-- Lazy submodule loading (snacks.nvim pattern).
-- rawset + rawget break the metamethod recursion: without rawget, every access
-- to an already-cached key would re-trigger __index.
setmetatable(M, {
  __index = function(t, k)
    local ok, mod = pcall(require, 'lazy-url.' .. k)
    if ok then
      rawset(t, k, mod)
      return rawget(t, k)
    end
  end,
})

-- Pre-setup state is valid: defaults applied at module load so callers
-- that never call setup() still get sensible behaviour.
local config_module = require('lazy-url.config')
M.config = vim.deepcopy(config_module.defaults)

--- Merge user opts into defaults. Idempotent — last call wins (resets then merges).
---@param opts? LazyUrl.Config
function M.setup(opts)
  M.config = config_module.merge(opts)
  config_module.validate(M.config)
end

--- Detect URL from cursor (normal mode) or visual selection (visual mode), then open.
---@return boolean launched true if a URL was found and dispatch began
function M.smart_open()
  local url = require('lazy-url.detect').find()
  if not url then
    vim.notify('lazy-url: no URL found under cursor', vim.log.levels.WARN)
    return false
  end
  return M.open(url)
end

--- Open the given URL via the dispatcher (custom-match → picker → exec).
---@param url string
---@return boolean launched true if dispatch began
function M.open(url)
  if type(url) ~= 'string' or url == '' then
    vim.notify('lazy-url: open() requires a non-empty URL string', vim.log.levels.WARN)
    return false
  end
  return require('lazy-url.open').open(url, M.config)
end

_G.LazyUrl = M

return M
