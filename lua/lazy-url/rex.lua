---Routing opens to the machine running the Rex app the user is typing from.
---
---All Rex knowledge lives here. `open.lua` calls `resolve(config, cb)` and gets
---either `nil` (open locally) or a route `{ host, send }`. Every unknown or
---failed lookup resolves to `nil`; nothing in discovery raises or notifies.
local M = {}

local LOOKUP_TIMEOUT = '5s'
local SEND_TIMEOUT = '10s'

---@class LazyUrl.RexRoute
---@field host string Rex host the open is sent to
---@field send fun(url: string, app: string|nil, on_fail: fun(err: string)) invoke the action on `host`

---Positive discovery results, keyed by the owning client id.
---@type table<string, {host: string, action: string, override: string|nil}>
local cache = {}

---Clear cached discovery results (e.g. after changing Rex hosts or actions).
function M.reset()
  cache = {}
end

---Walk nested tables, returning nil as soon as a level is not a table.
local function get(t, ...)
  for _, k in ipairs({ ... }) do
    if type(t) ~= 'table' then
      return nil
    end
    t = t[k]
  end
  return t
end

local function nonempty(s)
  return type(s) == 'string' and s ~= ''
end

---Locate the rex CLI: `$REX_BIN_DIR/rex` (the server's PATH may not contain
---it), then `rex` on PATH.
---@return string|nil
function M.bin()
  local dir = vim.env.REX_BIN_DIR
  if nonempty(dir) then
    local p = dir .. '/rex'
    if vim.fn.executable(p) == 1 then
      return p
    end
  end
  if vim.fn.executable('rex') == 1 then
    return 'rex'
  end
  return nil
end

---Run a command asynchronously; cb(result) runs on the main loop.
---A spawn failure is reported as a non-zero result.
---@param argv string[]
---@param timeout_ms integer hard kill in case the CLI's own --timeout is ignored
---@param cb fun(res: {code: integer, stdout: string, stderr: string})
local function run(argv, timeout_ms, cb)
  local done = vim.schedule_wrap(cb)
  local ok, err = pcall(vim.system, argv, { text = true, timeout = timeout_ms }, function(obj)
    done({ code = obj.code or -1, stdout = obj.stdout or '', stderr = obj.stderr or '' })
  end)
  if not ok then
    done({ code = -1, stdout = '', stderr = tostring(err) })
  end
end

---Run `rex [-S host] <args> [--json] --timeout 5s` and decode stdout as JSON.
---cb(nil) on any failure: non-zero exit, empty or malformed output.
---@param bin string
---@param host string|nil
---@param args string[]
---@param json_flag boolean append --json (`rex api call` prints JSON already and rejects the flag)
---@param cb fun(data: table|nil)
local function query(bin, host, args, json_flag, cb)
  local argv = { bin }
  if host then
    vim.list_extend(argv, { '-S', host })
  end
  vim.list_extend(argv, args)
  if json_flag then
    argv[#argv + 1] = '--json'
  end
  vim.list_extend(argv, { '--timeout', LOOKUP_TIMEOUT })
  run(argv, 6000, function(res)
    if res.code ~= 0 then
      return cb(nil)
    end
    local ok, data = pcall(vim.json.decode, res.stdout, { luanil = { object = true, array = true } })
    cb(ok and type(data) == 'table' and data or nil)
  end)
end
M._query = query

---Build a route that invokes `action` on `host`.
---@return LazyUrl.RexRoute
local function make_route(bin, host, action)
  return {
    host = host,
    send = function(url, app, on_fail)
      local payload = { url = url }
      if nonempty(app) then
        payload.app = app
      end
      local argv = { bin, '-S', host, 'do', action, '--args', vim.json.encode(payload), '--timeout', SEND_TIMEOUT }
      run(argv, 11000, function(res)
        if res.code ~= 0 then
          local err = vim.trim(res.stderr ~= '' and res.stderr or res.stdout)
          on_fail(err ~= '' and err or string.format('exit code %d', res.code))
        end
      end)
    end,
  }
end

---Does `client ls` output contain an app labelled `label` connected over unix
---(i.e. running on that host's machine)?
local function has_local_app(data, label)
  for _, c in ipairs(get(data, 'clients') or {}) do
    if
      get(c, 'info', 'kind') == 'app'
      and get(c, 'info', 'label') == label
      and get(c, 'principal', 'transport') == 'unix'
    then
      return true
    end
  end
  return false
end

---Find the host whose server has the app `label` connected locally.
---Probes all hosts in parallel; the first match in hosts.list order wins.
---@param cb fun(host: string|nil)
local function discover_host(bin, label, cb)
  query(bin, nil, { 'api', 'call', 'hosts.list' }, false, function(data)
    local labels = {}
    for _, h in ipairs(get(data, 'hosts') or {}) do
      if nonempty(get(h, 'label')) then
        labels[#labels + 1] = h.label
      end
    end
    if #labels == 0 then
      return cb(nil)
    end
    -- results[i]: nil = pending, true = match, false = no match
    local results = {}
    local finished = false
    local function settle()
      if finished then
        return
      end
      for i = 1, #labels do
        if results[i] == nil then
          return -- an earlier host is still pending; it would take priority
        elseif results[i] then
          finished = true
          return cb(labels[i])
        end
      end
      finished = true
      cb(nil)
    end
    for i, host in ipairs(labels) do
      query(bin, host, { 'client', 'ls' }, true, function(clients)
        results[i] = has_local_app(clients, label)
        settle()
      end)
    end
  end)
end

---Resolve where opens should go.
---cb(nil) means "open locally". cb runs synchronously when routing is
---disabled or Neovim is not in a Rex pane, asynchronously otherwise.
---@param config LazyUrl.Config
---@param cb fun(route: LazyUrl.RexRoute|nil)
function M.resolve(config, cb)
  local rex_cfg = type(config) == 'table' and type(config.rex) == 'table' and config.rex or {}
  local action, override = rex_cfg.action, rex_cfg.host
  local block = vim.env.REX_BLOCK
  if not nonempty(action) or not nonempty(block) then
    return cb(nil)
  end
  if not nonempty(override) then
    override = nil
  end
  local bin = M.bin()
  if not bin then
    return cb(nil)
  end

  -- 2. who owns the pane (the app the user last typed in)
  query(bin, nil, { 'block', 'inspect', block }, true, function(bdata)
    local owner = get(bdata, 'block', 'owner')
    if not nonempty(owner) then
      return cb(nil)
    end
    -- 3. is that app on this machine?
    query(bin, nil, { 'client', 'inspect', owner }, true, function(cdata)
      local client = get(cdata, 'client')
      local transport = get(client, 'principal', 'transport')
      if not nonempty(transport) or transport == 'unix' then
        return cb(nil)
      end
      local label = get(client, 'info', 'label')
      if not nonempty(label) and not override then
        return cb(nil)
      end

      -- 4. cache
      local hit = cache[owner]
      if hit and hit.action == action and hit.override == override then
        return cb(make_route(bin, hit.host, action))
      end

      -- 6. the action must exist on the target host
      local function check_action(host)
        if not host then
          return cb(nil)
        end
        query(bin, host, { 'actions' }, true, function(adata)
          for _, a in ipairs(get(adata, 'actions') or {}) do
            if get(a, 'name') == action then
              -- 7. cache positive results only
              cache[owner] = { host = host, action = action, override = override }
              return cb(make_route(bin, host, action))
            end
          end
          cb(nil)
        end)
      end

      -- 5. target host
      if override then
        check_action(override)
      else
        discover_host(bin, label, check_action)
      end
    end)
  end)
end

return M
