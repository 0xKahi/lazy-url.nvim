local M = {}

local os_name = (function()
  if vim.fn.has('mac') == 1 then
    return 'mac'
  elseif vim.fn.has('win32') == 1 or vim.fn.has('win64') == 1 then
    return 'windows'
  end
  return 'linux'
end)()

-- Exposed for tests.
M._os = function()
  return os_name
end
M._set_os = function(name)
  os_name = name
end

---User override for `name` (map-style config: browsers = { brave = { cmd = '...' } }).
---@return {cmd: string, args: string[]} | nil
local function override_spec(name, browsers_config)
  if type(browsers_config) == 'table' and type(browsers_config[name]) == 'table' then
    local override = browsers_config[name]
    if override.cmd then
      return { cmd = override.cmd, args = override.args or {} }
    end
  end
  return nil
end

---Command spec for `name` on `os`: user override first, then the preset. No warnings.
---@return {cmd: string, args: string[]} | {default: true} | nil
local function spec_for(name, browsers_config, presets, os)
  if name == 'default' then
    return { default = true }
  end
  local override = override_spec(name, browsers_config)
  if override then
    return override
  end
  local preset = presets[name]
  if preset and preset[os] then
    return preset[os]
  end
  return nil
end

---Resolve a browser name to its command spec for the current OS.
---Returns nil with a warning if the browser is unknown and has no preset.
---@param name string browser name (e.g. 'firefox', 'default')
---@param browsers_config table the config.browsers value (array or map)
---@param presets table M.presets from config.lua
---@return {cmd: string, args: string[]} | {default: true} | nil
local function resolve_browser(name, browsers_config, presets)
  local spec = spec_for(name, browsers_config, presets, os_name)
  if not spec then
    vim.notify(string.format('lazy-url: unknown browser %q (no preset for %s)', name, os_name), vim.log.levels.WARN)
  end
  return spec
end

---Application name to send to the Rex action (D5): the argument after `-a` in
---the browser's macOS spec (the user's override if it has `-a`, otherwise the
---mac preset). `default`, or no `-a`, means no app.
---@return string|nil
local function app_for(name, browsers_config, presets)
  if name == 'default' then
    return nil
  end
  local function after_a(spec)
    local args = spec and spec.args or {}
    for i, a in ipairs(args) do
      if a == '-a' and type(args[i + 1]) == 'string' and args[i + 1] ~= '' then
        return args[i + 1]
      end
    end
    return nil
  end
  local override = override_spec(name, browsers_config)
  local app = after_a(override)
  if app then
    return app
  end
  return after_a(presets[name] and presets[name].mac)
end

local function notify_error(msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.ERROR)
  end)
end

---Try to match url against the custom ordered list.
---Returns the handler's result; nil if no match (or the handler raised / returned
---non-string args, which falls through to the browsers as before); false if the
---result has an invalid shape (error shown, nothing is opened).
---A result with `cmd` is a local command; one with only `url` is transferable.
---@param url string
---@param custom_list table ordered list of {pattern, handler} entries
---@return {kind: 'cmd', cmd: string, args: string[]} | {kind: 'url', url: string, app: string|nil} | false | nil
local function match_custom(url, custom_list)
  for _, entry in ipairs(custom_list) do
    if url:match(entry.pattern) then
      local ok, result = pcall(entry.handler, url)
      if not ok then
        notify_error(string.format('lazy-url: custom handler error: %s', tostring(result)))
        return nil
      end
      if type(result) ~= 'table' or (type(result.cmd) ~= 'string' and type(result.url) ~= 'string') then
        notify_error(
          'lazy-url: custom handler must return { url = string, app? = string } or { cmd = string, args? = string[] }'
        )
        return false
      end
      -- `cmd` wins when both are present, so pre-existing handlers behave as before.
      if type(result.cmd) ~= 'string' then
        if result.url == '' then
          notify_error('lazy-url: custom handler returned an empty url')
          return false
        end
        if result.app ~= nil and type(result.app) ~= 'string' then
          notify_error(string.format('lazy-url: custom handler app must be a string, got %s', type(result.app)))
          return false
        end
        return { kind = 'url', url = result.url, app = result.app ~= '' and result.app or nil }
      end
      -- Every arg must be a string. Common failure mode: `{ url:gsub('a', 'b') }`
      -- captures gsub's two return values (string, count), so args[2] becomes the
      -- replacement count (a number). vim.system would then pass that count to the
      -- subprocess as a positional arg. Wrap gsub in parens — `{ (url:gsub(...)) }` —
      -- to discard the count.
      local args = result.args or {}
      for i, a in ipairs(args) do
        if type(a) ~= 'string' then
          notify_error(
            string.format(
              'lazy-url: custom handler args[%d] must be a string, got %s (%s). '
                .. "Hint: `{ url:gsub(...) }` captures gsub's replacement count too — "
                .. 'wrap in parens: `{ (url:gsub(...)) }`.',
              i,
              type(a),
              tostring(a)
            )
          )
          return nil
        end
      end
      return { kind = 'cmd', cmd = result.cmd, args = args }
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

---Open a local spec: `default` (or no spec) goes to vim.ui.open.
local function open_spec(spec, url)
  if not spec or spec.default then
    vim.ui.open(url)
  else
    exec(spec, url)
  end
end

---Open a custom handler URL result on this machine.
---On macOS with an app: `open -a <app> <url>`; otherwise vim.ui.open.
local function open_url_result_locally(result)
  if result.app and os_name == 'mac' then
    exec({ cmd = 'open', args = { '-a', result.app } }, result.url)
  else
    vim.ui.open(result.url)
  end
end

---Send via Rex; on failure warn and run `fallback` locally.
---@param route LazyUrl.RexRoute
local function send(route, url, app, fallback)
  route.send(url, app, function(err)
    vim.notify(
      string.format('lazy-url: rex open failed (%s): %s; opening locally', route.host, err),
      vim.log.levels.WARN
    )
    fallback()
  end)
end

---Configured browser names, in order: the array part, then map-style override keys.
local function browser_names(browsers)
  local names, seen = {}, {}
  for _, name in ipairs(browsers) do
    seen[name] = true
    names[#names + 1] = name
  end
  -- Also handle map-style overrides: browsers = { 'default', brave = { cmd = '...' } }
  -- ipairs only covers the array part; named keys (overrides) added separately
  for k, v in pairs(browsers) do
    if type(k) == 'string' and type(v) == 'table' and not seen[k] then
      seen[k] = true
      names[#names + 1] = k
    end
  end
  return names
end

---Build picker items.
---Local: specs for this OS; unknown browsers are dropped with a warning.
---Routed (D6): every browser with a macOS spec, an override, or `default`, since
---the receiving end is the user's machine; `local_spec` may be nil.
---@return {name: string, resolved: table|nil, app: string|nil}[]
local function build_items(browsers, presets, routed)
  local items = {}
  for _, name in ipairs(browser_names(browsers)) do
    if routed then
      if spec_for(name, browsers, presets, 'mac') then
        items[#items + 1] = {
          name = name,
          resolved = spec_for(name, browsers, presets, os_name),
          app = app_for(name, browsers, presets),
        }
      else
        vim.notify(string.format('lazy-url: unknown browser %q (no preset for mac)', name), vim.log.levels.WARN)
      end
    else
      local resolved = resolve_browser(name, browsers, presets)
      if resolved then
        items[#items + 1] = { name = name, resolved = resolved }
      end
    end
  end
  return items
end

---Dispatch once the route is known.
---@param url string
---@param config table merged LazyUrl.Config
---@param route LazyUrl.RexRoute|nil nil = open locally
---@return boolean
local function dispatch(url, config, route)
  local cfg_module = require('lazy-url.config')

  -- 1. Custom pattern match (ordered, first wins, bypasses picker)
  if config.custom and #config.custom > 0 then
    local result = match_custom(url, config.custom)
    if result == false then
      return false -- invalid handler result: error already shown, open nothing
    elseif result then
      if result.kind == 'cmd' then
        exec(result, nil) -- handler args already include the (transformed) URL; always local
      elseif route then
        send(route, result.url, result.app, function()
          open_url_result_locally(result)
        end)
      else
        open_url_result_locally(result)
      end
      return true
    end
  end

  local browsers = config.browsers or { 'default' }
  local items = build_items(browsers, cfg_module.presets, route ~= nil)

  if #items == 0 then
    vim.notify('lazy-url: no valid browsers configured', vim.log.levels.WARN)
    return false
  end

  local function launch(item)
    if route then
      send(route, url, item.app, function()
        open_spec(item.resolved, url)
      end)
    else
      open_spec(item.resolved, url)
    end
  end

  -- 2. Single browser — open directly without picker
  if #items == 1 then
    launch(items[1])
    return true
  end

  -- 3. Multiple browsers — show picker
  vim.ui.select(items, {
    prompt = route and string.format('Open URL on %s with:', route.host) or 'Open URL with:',
    format_item = function(item)
      return item.name
    end,
  }, function(choice)
    if choice then
      launch(choice)
    end
  end)

  return true
end

---Open url using the dispatcher:
---  0. Resolve a Rex route (async; immediate when rex.action is unset or not in Rex)
---  1. Check custom ordered list — if match, run/send the handler result (no picker)
---  2. If single browser, open directly (no picker)
---  3. If 2+ browsers, show vim.ui.select picker
---@param url string
---@param config table merged LazyUrl.Config
---@return boolean true if dispatch was attempted or scheduled
function M.open(url, config)
  if type(url) ~= 'string' or url == '' then
    vim.notify('lazy-url: open() requires a non-empty URL string', vim.log.levels.WARN)
    return false
  end

  local result
  require('lazy-url.rex').resolve(config, function(route)
    result = dispatch(url, config, route)
  end)
  -- nil: resolution is still running; dispatch is scheduled.
  if result == nil then
    return true
  end
  return result
end

return M
