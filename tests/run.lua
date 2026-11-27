-- Minimal headless test runner.
--
--   nvim --headless -l tests/run.lua                 -- run every tests/*_spec.lua
--   nvim --headless -l tests/run.lua tests/x_spec.lua -- run only the given files
--
-- Exits 0 when every test passes, 1 otherwise.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
package.path =
  table.concat({ root .. '/lua/?.lua', root .. '/lua/?/init.lua', root .. '/tests/?.lua', package.path }, ';')

local T = {}
_G.T = T

-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------

local real = {
  system = vim.system,
  ui_open = vim.ui.open,
  ui_select = vim.ui.select,
  notify = vim.notify,
}

---Recorded calls, reset before each test.
---@type { system: {argv: string[], opts: table}[], ui_open: string[], ui_select: {items: table, opts: table}[], notify: {msg: string, level: integer}[] }
T.calls = {}

---Responder for vim.system: fun(argv, opts) -> { code?, stdout?, stderr? } | nil (nil = code 0, empty output).
---May raise to simulate a spawn failure (e.g. ENOENT).
T.system_handler = nil

---Callback picking an item for vim.ui.select: fun(items, opts) -> item | nil.
T.select_handler = nil

local function reset_stubs()
  T.calls = { system = {}, ui_open = {}, ui_select = {}, notify = {} }
  T.system_handler = nil
  T.select_handler = nil
end

vim.system = function(argv, opts, on_exit)
  if type(opts) == 'function' then
    on_exit, opts = opts, nil
  end
  opts = opts or {}
  table.insert(T.calls.system, { argv = vim.deepcopy(argv), opts = opts })
  local res = T.system_handler and T.system_handler(argv, opts) or {}
  local out = { code = res.code or 0, signal = 0, stdout = res.stdout or '', stderr = res.stderr or '' }
  if on_exit then
    on_exit(out)
  end
  return {
    wait = function()
      return out
    end,
    kill = function() end,
    pid = 0,
  }
end

vim.ui.open = function(url)
  table.insert(T.calls.ui_open, url)
  return nil, nil
end

vim.ui.select = function(items, opts, on_choice)
  table.insert(T.calls.ui_select, { items = items, opts = opts })
  local choice = T.select_handler and T.select_handler(items, opts) or nil
  on_choice(choice)
end

vim.notify = function(msg, level)
  table.insert(T.calls.notify, { msg = msg, level = level })
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

---Process pending vim.schedule callbacks.
function T.flush()
  vim.wait(20, function()
    return false
  end, 1)
end

---Wait until cond() is truthy (or timeout); returns the final cond() result.
function T.wait_for(cond, timeout)
  vim.wait(timeout or 500, cond, 1)
  return cond()
end

local function fmt(v)
  return vim.inspect(v, { newline = ' ', indent = '' })
end

function T.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(string.format('%sexpected %s, got %s', msg and (msg .. ': ') or '', fmt(expected), fmt(actual)), 2)
  end
end

function T.ok(v, msg)
  if not v then
    error(msg or 'expected truthy value', 2)
  end
end

---Assert fn raises an error whose message contains `pattern` (plain find).
function T.raises(fn, pattern)
  local ok, err = pcall(fn)
  if ok then
    error('expected an error' .. (pattern and (' matching ' .. pattern) or ''), 2)
  end
  if pattern and not tostring(err):find(pattern, 1, true) then
    error(string.format('error %q does not contain %q', tostring(err), pattern), 2)
  end
end

---Notifications at or above `level`.
function T.notified(level)
  local out = {}
  for _, n in ipairs(T.calls.notify) do
    if n.level == level then
      out[#out + 1] = n.msg
    end
  end
  return out
end

---Commands passed to vim.system, as argv arrays.
function T.argvs()
  local out = {}
  for _, c in ipairs(T.calls.system) do
    out[#out + 1] = c.argv
  end
  return out
end

---Reload every lazy-url module so tests don't share module state.
function T.fresh()
  for name in pairs(package.loaded) do
    if name == 'lazy-url' or name:match('^lazy%-url%.') then
      package.loaded[name] = nil
    end
  end
  _G.LazyUrl = nil
end

-- ---------------------------------------------------------------------------
-- Runner
-- ---------------------------------------------------------------------------

local tests = {}
local current_file

function T.describe(name, fn)
  local prev = T._prefix
  T._prefix = (prev and (prev .. ' > ') or '') .. name
  fn()
  T._prefix = prev
end

function T.it(name, fn)
  tests[#tests + 1] = { name = (T._prefix and (T._prefix .. ' > ') or '') .. name, fn = fn, file = current_file }
end

_G.describe = T.describe
_G.it = T.it

local files = {}
for _, a in ipairs(_G.arg or {}) do
  files[#files + 1] = a
end
if #files == 0 then
  files = vim.fn.glob(root .. '/tests/*_spec.lua', false, true)
  table.sort(files)
end

for _, f in ipairs(files) do
  current_file = vim.fn.fnamemodify(f, ':t')
  local chunk, err = loadfile(f)
  if not chunk then
    io.stderr:write('load error: ' .. tostring(err) .. '\n')
    os.exit(1)
  end
  chunk()
end

local saved_env = vim.fn.environ()
local failed = 0
for _, t in ipairs(tests) do
  reset_stubs()
  T.fresh()
  local ok, err = xpcall(t.fn, debug.traceback)
  T.flush()
  -- restore environment changed by the test
  for k in pairs(vim.fn.environ()) do
    if saved_env[k] == nil then
      vim.env[k] = nil
    end
  end
  for k, v in pairs(saved_env) do
    if vim.env[k] ~= v then
      vim.env[k] = v
    end
  end
  if ok then
    io.stdout:write('  ok   ' .. t.file .. ': ' .. t.name .. '\n')
  else
    failed = failed + 1
    io.stdout:write('  FAIL ' .. t.file .. ': ' .. t.name .. '\n' .. tostring(err):gsub('\n', '\n       ') .. '\n')
  end
end

-- keep references to the real functions reachable for debugging
T.real = real

io.stdout:write(string.format('\n%d tests, %d failed\n', #tests, failed))
os.exit(failed == 0 and 0 or 1)
