local M = {}

local os_name = (function()
  if vim.fn.has('mac') == 1 then
    return 'mac'
  elseif vim.fn.has('win32') == 1 or vim.fn.has('win64') == 1 then
    return 'windows'
  end
  return 'linux'
end)()

---Resolve a browser name to its command spec for the current OS.
---Returns nil with a warning if the browser is unknown and has no preset.
---@param name string browser name (e.g. 'firefox', 'default')
---@param browsers_config table the config.browsers value (array or map)
---@param presets table M.presets from config.lua
---@return {cmd: string, args: string[]} | {default: true} | nil
local function resolve_browser(name, browsers_config, presets)
  if name == 'default' then
    return { default = true }
  end
  -- Check for user cmd override (map-style config: browsers = { brave = { cmd = '...' } })
  if type(browsers_config) == 'table' and type(browsers_config[name]) == 'table' then
    local override = browsers_config[name]
    if override.cmd then
      return { cmd = override.cmd, args = override.args or {} }
    end
  end
  -- Fall back to preset for this OS
  local preset = presets[name]
  if preset and preset[os_name] then
    return preset[os_name]
  end
  vim.notify(string.format('lazy-url: unknown browser %q (no preset for %s)', name, os_name), vim.log.levels.WARN)
  return nil
end

---Try to match url against the custom ordered list.
---Returns the command spec from the handler, or nil if no match.
---@param url string
---@param custom_list table ordered list of {pattern, handler} entries
---@return {cmd: string, args: string[]} | nil
local function match_custom(url, custom_list)
  for _, entry in ipairs(custom_list) do
    if url:match(entry.pattern) then
      local ok, result = pcall(entry.handler, url)
      if not ok then
        vim.schedule(function()
          vim.notify(string.format('lazy-url: custom handler error: %s', tostring(result)), vim.log.levels.ERROR)
        end)
        return nil
      end
      if type(result) ~= 'table' or type(result.cmd) ~= 'string' then
        vim.schedule(function()
          vim.notify('lazy-url: custom handler must return { cmd = string, args? = table }', vim.log.levels.ERROR)
        end)
        return nil
      end
      -- Every arg must be a string. Common failure mode: `{ url:gsub('a', 'b') }`
      -- captures gsub's two return values (string, count), so args[2] becomes the
      -- replacement count (a number). vim.system would then pass that count to the
      -- subprocess as a positional arg. Wrap gsub in parens — `{ (url:gsub(...)) }` —
      -- to discard the count.
      local args = result.args or {}
      for i, a in ipairs(args) do
        if type(a) ~= 'string' then
          vim.schedule(function()
            vim.notify(
              string.format(
                'lazy-url: custom handler args[%d] must be a string, got %s (%s). '
                  .. 'Hint: `{ url:gsub(...) }` captures gsub\'s replacement count too — '
                  .. 'wrap in parens: `{ (url:gsub(...)) }`.',
                i,
                type(a),
                tostring(a)
              ),
              vim.log.levels.ERROR
            )
          end)
          return nil
        end
      end
      return { cmd = result.cmd, args = args }
    end
  end
  return nil
end

---Execute a browser command with the given URL appended.
---For custom handlers, args already contain the (possibly transformed) URL — do NOT append url again.
---@param cmd_spec {cmd: string, args: string[]}
---@param url string | nil url to append (nil = handler already encoded it in args)
local function exec(cmd_spec, url)
  local argv = { cmd_spec.cmd }
  for _, a in ipairs(cmd_spec.args or {}) do
    argv[#argv + 1] = a
  end
  if url then
    argv[#argv + 1] = url
  end
  vim.system(argv, { detach = true }, function(obj)
    if obj.code ~= 0 then
      vim.schedule(function()
        vim.notify(
          string.format('lazy-url: launch failed (code %d): %s', obj.code, obj.stderr or ''),
          vim.log.levels.ERROR
        )
      end)
    end
  end)
end

---Open url using the dispatcher:
---  1. Check custom ordered list — if match, exec handler command directly (no picker)
---  2. If single browser, open directly (no picker)
---  3. If 2+ browsers, show vim.ui.select picker
---@param url string
---@param config table merged LazyUrl.Config
---@return boolean true if dispatch was attempted
function M.open(url, config)
  if type(url) ~= 'string' or url == '' then
    vim.notify('lazy-url: open() requires a non-empty URL string', vim.log.levels.WARN)
    return false
  end

  local cfg_module = require('lazy-url.config')

  -- 1. Custom pattern match (ordered, first wins, bypasses picker)
  if config.custom and #config.custom > 0 then
    local custom_spec = match_custom(url, config.custom)
    if custom_spec then
      exec(custom_spec, nil) -- handler args already include the (transformed) URL
      return true
    end
  end

  -- Resolve browser list to items
  local browsers = config.browsers or { 'default' }
  local items = {}
  for _, name in ipairs(browsers) do
    local resolved = resolve_browser(name, browsers, cfg_module.presets)
    if resolved then
      items[#items + 1] = { name = name, resolved = resolved }
    end
  end

  -- Also handle map-style overrides: browsers = { 'default', brave = { cmd = '...' } }
  -- ipairs only covers the array part; named keys (overrides) added separately
  if type(browsers) == 'table' then
    for k, v in pairs(browsers) do
      if type(k) == 'string' and type(v) == 'table' then
        local resolved = resolve_browser(k, browsers, cfg_module.presets)
        if resolved then
          -- Avoid duplicates
          local found = false
          for _, item in ipairs(items) do
            if item.name == k then
              found = true
              break
            end
          end
          if not found then
            items[#items + 1] = { name = k, resolved = resolved }
          end
        end
      end
    end
  end

  if #items == 0 then
    vim.notify('lazy-url: no valid browsers configured', vim.log.levels.WARN)
    return false
  end

  -- 2. Single browser — open directly without picker
  if #items == 1 then
    local item = items[1]
    if item.resolved.default then
      vim.ui.open(url)
    else
      exec(item.resolved, url)
    end
    return true
  end

  -- 3. Multiple browsers — show picker
  vim.ui.select(items, {
    prompt = 'Open URL with:',
    format_item = function(item)
      return item.name
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.resolved.default then
      vim.ui.open(url)
    else
      exec(choice.resolved, url)
    end
  end)

  return true
end

return M
