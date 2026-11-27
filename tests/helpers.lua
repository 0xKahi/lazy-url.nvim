-- Shared fixtures: a fake rex binary and a scripted Rex CLI behind the vim.system stub.
local H = {}

local bin_dir = vim.fn.tempname()
vim.fn.mkdir(bin_dir, 'p')
local bin = bin_dir .. '/rex'
vim.fn.writefile({ '#!/bin/sh', 'exit 0' }, bin)
vim.fn.setfperm(bin, 'rwxr-xr-x')
H.bin_dir, H.bin = bin_dir, bin

---Enter a Rex pane: REX_BLOCK + REX_BIN_DIR pointing at the fake binary.
function H.in_rex()
  vim.env.REX_BLOCK = 'block:1'
  vim.env.REX_BIN_DIR = bin_dir
end

local function json(t)
  return { stdout = vim.json.encode(t) }
end

local function app(label, transport, id)
  return {
    client_id = id or ('client:' .. label),
    info = { kind = 'app', label = label },
    principal = { transport = transport },
  }
end
H.app = app

---Scripted Rex world.
---@param w {owner?: string, owner_label?: string, owner_transport?: string, hosts?: string[], clients?: table<string, table[]>, actions?: table<string, string[]>, unreachable?: table<string, boolean>, do_code?: integer}
function H.world(w)
  w.owner = w.owner == nil and 'client:owner' or w.owner
  w.owner_transport = w.owner_transport or 'tailscale'
  w.hosts = w.hosts or {}
  w.clients = w.clients or {}
  w.actions = w.actions or {}
  w.unreachable = w.unreachable or {}
  T.system_handler = function(argv)
    if argv[1] ~= bin then
      return { code = 0 } -- local launches (open, browsers)
    end
    local i, host = 2, nil
    if argv[2] == '-S' then
      host, i = argv[3], 4
    end
    if host and w.unreachable[host] then
      return { code = 1, stderr = 'Error: timed out' }
    end
    local cmd = table.concat({ argv[i], argv[i + 1] or '' }, ' ')
    if cmd == 'block inspect' then
      return json({ block = { owner = w.owner ~= false and w.owner or nil } })
    elseif cmd == 'client inspect' then
      local c = app(w.owner_label, w.owner_transport, w.owner)
      return json({ client = c })
    elseif cmd == 'api call' then
      local hosts = {}
      for _, h in ipairs(w.hosts) do
        hosts[#hosts + 1] = { label = h, endpoints = { 'https://' .. h } }
      end
      return json({ hosts = hosts })
    elseif cmd == 'client ls' then
      return json({ clients = w.clients[host] or {} })
    elseif argv[i] == 'actions' then
      local list = {}
      for _, name in ipairs(w.actions[host] or {}) do
        list[#list + 1] = { name = name, kind = 'lua' }
      end
      return json({ actions = list })
    elseif argv[i] == 'do' then
      return { code = w.do_code or 0, stderr = w.do_code and w.do_code ~= 0 and 'Error: action failed' or '' }
    end
    return { code = 1, stderr = 'unknown command' }
  end
  return w
end

---The standard remote setup: pane owned by app `jojo-mac` (remote), whose
---server is host `kahi-mac-rex` and defines `lazy_url_open`.
function H.remote_world(extra)
  return H.world(vim.tbl_extend('force', {
    owner_label = 'jojo-mac',
    hosts = { 'kahi-mac-rex' },
    clients = { ['kahi-mac-rex'] = { app('jojo-mac', 'unix') } },
    actions = { ['kahi-mac-rex'] = { 'lazy_url_open' } },
  }, extra or {}))
end

---Rex CLI invocations (argv after the binary), filtered from recorded vim.system calls.
function H.rex_calls()
  local out = {}
  for _, argv in ipairs(T.argvs()) do
    if argv[1] == bin then
      out[#out + 1] = vim.list_slice(argv, 2)
    end
  end
  return out
end

---Non-rex vim.system calls (local launches).
function H.local_calls()
  local out = {}
  for _, argv in ipairs(T.argvs()) do
    if argv[1] ~= bin then
      out[#out + 1] = argv
    end
  end
  return out
end

---The `rex do` call, if any, with its decoded --args payload.
---@return {host: string, action: string, args: table}|nil
function H.sent()
  for _, a in ipairs(H.rex_calls()) do
    if a[1] == '-S' and a[3] == 'do' then
      local payload
      for i, v in ipairs(a) do
        if v == '--args' then
          payload = vim.json.decode(a[i + 1])
        end
      end
      return { host = a[2], action = a[4], args = payload, argv = a }
    end
  end
  return nil
end

---Resolve synchronously-ish: run rex.resolve and wait for the callback.
function H.resolve(config)
  local done, route = false, nil
  require('lazy-url.rex').resolve(config, function(r)
    done, route = true, r
  end)
  T.ok(
    T.wait_for(function()
      return done
    end),
    'resolve did not call back'
  )
  return route
end

return H
