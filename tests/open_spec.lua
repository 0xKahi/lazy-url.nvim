local H = require('helpers')
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

local function setup(opts)
  local lazy = require('lazy-url')
  lazy.setup(opts)
  return lazy
end

local function set_os(name)
  require('lazy-url.open')._set_os(name)
end

local function discord_handler(app)
  return {
    pattern = 'discord%.com',
    handler = function(url)
      return { url = (url:gsub('^https://', 'discord://')), app = app }
    end,
  }
end

local URL = 'https://discord.com/channels/1'

describe('2.1 custom handler results', function()
  it('URL result while local: opened with the app, no picker (macOS)', function()
    set_os('mac')
    setup({ browsers = { 'firefox', 'arc' }, custom = { discord_handler('Discord') } })
    T.eq(true, LazyUrl.open(URL))
    T.eq({ { 'open', '-a', 'Discord', 'discord://discord.com/channels/1' } }, T.argvs())
    T.eq({}, T.calls.ui_select)
  end)

  it('Command result: runs locally as before', function()
    setup({
      browsers = { 'firefox', 'arc' },
      custom = {
        {
          pattern = 'discord%.com',
          handler = function(url)
            return { cmd = 'open', args = { (url:gsub('^https://', 'discord://')) } }
          end,
        },
      },
    })
    LazyUrl.open(URL)
    T.eq({ { 'open', 'discord://discord.com/channels/1' } }, T.argvs())
    T.eq({}, T.calls.ui_select)
  end)

  it('cmd wins when a handler returns both cmd and url', function()
    setup({
      custom = {
        {
          pattern = '.',
          handler = function()
            return { cmd = 'xdg-open', args = { 'x' }, url = 'y' }
          end,
        },
      },
    })
    LazyUrl.open(URL)
    T.eq({ { 'xdg-open', 'x' } }, T.argvs())
  end)

  for name, ret in pairs({
    ['neither url nor cmd'] = { args = { 'x' } },
    ['non-table'] = 'discord://x',
    ['non-string url'] = { url = 42 },
    ['non-string app'] = { url = 'discord://x', app = 1 },
    ['empty url'] = { url = '' },
  }) do
    it('Invalid handler result (' .. name .. '): error, nothing opened', function()
      setup({
        custom = {
          {
            pattern = '.',
            handler = function()
              return ret
            end,
          },
        },
      })
      LazyUrl.open(URL)
      T.flush()
      T.eq(1, #T.notified(vim.log.levels.ERROR))
      T.eq({}, T.calls.system)
      T.eq({}, T.calls.ui_open)
      T.eq({}, T.calls.ui_select)
    end)
  end
end)

describe('2.2 local URL results', function()
  it('macOS without app -> vim.ui.open', function()
    set_os('mac')
    setup({ browsers = { 'firefox', 'arc' }, custom = { discord_handler(nil) } })
    LazyUrl.open(URL)
    T.eq({ 'discord://discord.com/channels/1' }, T.calls.ui_open)
    T.eq({}, T.calls.system)
    T.eq({}, T.calls.ui_select)
  end)

  it('Linux with app -> vim.ui.open (app is macOS-only)', function()
    set_os('linux')
    setup({ browsers = { 'firefox', 'arc' }, custom = { discord_handler('Discord') } })
    LazyUrl.open(URL)
    T.eq({ 'discord://discord.com/channels/1' }, T.calls.ui_open)
    T.eq({}, T.calls.system)
    T.eq({}, T.calls.ui_select)
  end)
end)

describe('4.1 unchanged without rex.action', function()
  -- Load the pre-change dispatcher as a golden reference.
  local function old_open()
    return dofile(root .. '/tests/fixtures/open_pre_rex.lua')
  end

  local function record(fn)
    T.calls = { system = {}, ui_open = {}, ui_select = {}, notify = {} }
    fn()
    T.flush()
    local selects = {}
    for _, s in ipairs(T.calls.ui_select) do
      local names = {}
      for _, item in ipairs(s.items) do
        names[#names + 1] = item.name
      end
      table.sort(names) -- map-style key order comes from pairs()
      selects[#selects + 1] = { prompt = s.opts.prompt, names = names }
    end
    return { system = T.argvs(), ui_open = T.calls.ui_open, ui_select = selects, notify = T.calls.notify }
  end

  local scenarios = {
    { name = 'single default', opts = {} },
    { name = 'single preset', opts = { browsers = { 'firefox' } } },
    { name = 'picker choice', opts = { browsers = { 'default', 'firefox', 'arc' } }, pick = 'firefox' },
    { name = 'picker default', opts = { browsers = { 'default', 'firefox' } }, pick = 'default' },
    { name = 'picker cancelled', opts = { browsers = { 'default', 'firefox' } } },
    { name = 'unknown browser', opts = { browsers = { 'nope', 'firefox' } }, pick = 'firefox' },
    { name = 'no valid browsers', opts = { browsers = { 'nope' } } },
    {
      name = 'map-style override',
      opts = { browsers = { 'default', brave = { cmd = 'open', args = { '-a', 'Brave Beta' } } } },
      pick = 'brave',
    },
    {
      name = 'custom cmd',
      opts = {
        custom = {
          {
            pattern = 'example',
            handler = function(u)
              return { cmd = 'echo', args = { u } }
            end,
          },
        },
      },
    },
    {
      name = 'custom handler error',
      opts = {
        custom = {
          {
            pattern = 'example',
            handler = function()
              error('x', 0)
            end,
          },
        },
      },
    },
    {
      name = 'custom bad args',
      opts = {
        custom = {
          {
            pattern = 'example',
            handler = function(u)
              return { cmd = 'echo', args = { u:gsub('a', 'b') } }
            end,
          },
        },
      },
    },
    {
      name = 'custom no match',
      opts = {
        browsers = { 'firefox' },
        custom = {
          {
            pattern = 'nomatch',
            handler = function()
              return { cmd = 'x' }
            end,
          },
        },
      },
    },
  }

  for _, os in ipairs({ 'mac', 'linux' }) do
    for _, sc in ipairs(scenarios) do
      it(os .. ': ' .. sc.name .. ' (inside a Rex pane, rex.action unset)', function()
        H.in_rex()
        H.remote_world()
        local config = require('lazy-url.config').merge(sc.opts)
        T.select_handler = function(items)
          for _, it in ipairs(items) do
            if it.name == sc.pick then
              return it
            end
          end
        end
        -- both modules capture the OS at load time; force them to the same one
        local old_ret, new_ret
        local had = vim.fn.has
        vim.fn.has = function(f)
          if f == 'mac' then
            return os == 'mac' and 1 or 0
          elseif f == 'win32' or f == 'win64' then
            return 0
          end
          return had(f)
        end
        local old = old_open()
        vim.fn.has = had
        require('lazy-url.open')._set_os(os)
        local before = record(function()
          old_ret = old.open('https://example.com/a', config)
        end)
        local after = record(function()
          new_ret = require('lazy-url.open').open('https://example.com/a', config)
        end)
        T.eq(old_ret, new_ret, 'return value')
        T.eq(before, after)
        T.eq({}, H.rex_calls())
      end)
    end
  end
end)

local routed = { rex = { action = 'lazy_url_open' } }

local function pick(name)
  T.select_handler = function(items)
    for _, it in ipairs(items) do
      if it.name == name then
        return it
      end
    end
  end
end

local function open_routed(url)
  T.eq(true, LazyUrl.open(url or 'https://example.com'))
  T.ok(
    T.wait_for(function()
      return H.sent() ~= nil or #H.local_calls() > 0 or #T.calls.ui_open > 0
    end),
    'nothing was opened or sent'
  )
  T.flush()
end

describe('4.1 routed custom results', function()
  it('URL result while routed: sent, no picker', function()
    H.in_rex()
    H.remote_world()
    setup(vim.tbl_extend('force', routed, { browsers = { 'firefox', 'arc' }, custom = { discord_handler(nil) } }))
    open_routed(URL)
    T.eq({ url = 'discord://discord.com/channels/1' }, H.sent().args)
    T.eq({}, T.calls.ui_select)
    T.eq({}, H.local_calls())
  end)

  it('URL result with app while routed: app is sent', function()
    H.in_rex()
    H.remote_world()
    setup(vim.tbl_extend('force', routed, { custom = { discord_handler('Discord') } }))
    open_routed(URL)
    T.eq({ url = 'discord://discord.com/channels/1', app = 'Discord' }, H.sent().args)
  end)

  it('Command result while routed: runs locally', function()
    H.in_rex()
    H.remote_world()
    setup(vim.tbl_extend('force', routed, {
      custom = {
        {
          pattern = 'discord',
          handler = function()
            return { cmd = 'open', args = { 'discord://x' } }
          end,
        },
      },
    }))
    open_routed(URL)
    T.eq(nil, H.sent())
    T.eq({ { 'open', 'discord://x' } }, H.local_calls())
  end)

  it('not routed (owner local): URL result opens locally', function()
    set_os('mac')
    H.in_rex()
    H.remote_world({ owner_transport = 'unix' })
    setup(vim.tbl_extend('force', routed, { custom = { discord_handler('Discord') } }))
    open_routed(URL)
    T.eq(nil, H.sent())
    T.eq({ { 'open', '-a', 'Discord', 'discord://discord.com/channels/1' } }, H.local_calls())
  end)
end)

describe('4.2 routed browsers', function()
  it('Browser chosen from picker: app=Arc', function()
    H.in_rex()
    H.remote_world()
    set_os('linux')
    pick('arc')
    setup(vim.tbl_extend('force', routed, { browsers = { 'firefox', 'arc' } }))
    open_routed()
    T.eq({ url = 'https://example.com', app = 'Arc' }, H.sent().args)
    T.eq({}, H.local_calls())
  end)

  it('picker on Linux offers mac-only browsers (arc) without warnings', function()
    H.in_rex()
    H.remote_world()
    set_os('linux')
    setup(vim.tbl_extend('force', routed, { browsers = { 'default', 'firefox', 'arc', 'safari' } }))
    LazyUrl.open('https://example.com')
    T.wait_for(function()
      return #T.calls.ui_select > 0
    end)
    local names = vim.tbl_map(function(i)
      return i.name
    end, T.calls.ui_select[1].items)
    T.eq({ 'default', 'firefox', 'arc', 'safari' }, names)
    T.eq({}, T.notified(vim.log.levels.WARN))
    T.ok(T.calls.ui_select[1].opts.prompt:find('kahi-mac-rex', 1, true), 'prompt names the host')
  end)

  it('Default browser: no app', function()
    H.in_rex()
    H.remote_world()
    pick('default')
    setup(vim.tbl_extend('force', routed, { browsers = { 'default', 'arc' } }))
    open_routed()
    T.eq({ url = 'https://example.com' }, H.sent().args)
  end)

  it('single default browser: sent directly without picker', function()
    H.in_rex()
    H.remote_world()
    setup(routed)
    open_routed()
    T.eq({ url = 'https://example.com' }, H.sent().args)
    T.eq({}, T.calls.ui_select)
    T.eq({}, T.calls.ui_open)
  end)

  it('Browser override with an app name', function()
    H.in_rex()
    H.remote_world()
    pick('brave')
    setup(vim.tbl_extend('force', routed, {
      browsers = { 'default', brave = { cmd = 'open', args = { '-a', '/Applications/Brave Beta.app' } } },
    }))
    open_routed()
    T.eq({ url = 'https://example.com', app = '/Applications/Brave Beta.app' }, H.sent().args)
  end)

  it('override without -a falls back to the mac preset app', function()
    H.in_rex()
    H.remote_world()
    set_os('linux')
    pick('brave')
    setup(vim.tbl_extend('force', routed, { browsers = { 'default', brave = { cmd = 'brave-beta' } } }))
    open_routed()
    T.eq({ url = 'https://example.com', app = 'Brave Browser' }, H.sent().args)
  end)

  it('Browser without an app name: no app', function()
    H.in_rex()
    H.remote_world()
    pick('mybrowser')
    setup(vim.tbl_extend('force', routed, { browsers = { 'default', mybrowser = { cmd = 'mybrowser' } } }))
    open_routed()
    T.eq({ url = 'https://example.com' }, H.sent().args)
  end)

  it('picker cancelled: nothing sent', function()
    H.in_rex()
    H.remote_world()
    setup(vim.tbl_extend('force', routed, { browsers = { 'default', 'arc' } }))
    LazyUrl.open('https://example.com')
    T.wait_for(function()
      return #T.calls.ui_select > 0
    end)
    T.flush()
    T.eq(nil, H.sent())
  end)
end)

describe('4.3 fallback on send failure', function()
  it('Action errors at runtime: same choice opens locally + WARN naming host and error', function()
    H.in_rex()
    H.remote_world({ do_code = 1 })
    set_os('mac')
    pick('arc')
    setup(vim.tbl_extend('force', routed, { browsers = { 'firefox', 'arc' } }))
    LazyUrl.open('https://example.com')
    T.ok(
      T.wait_for(function()
        return #H.local_calls() > 0
      end),
      'expected a local fallback'
    )
    T.eq({ { 'open', '-a', 'Arc', 'https://example.com' } }, H.local_calls())
    local warns = T.notified(vim.log.levels.WARN)
    T.eq(1, #warns)
    T.ok(warns[1]:find('kahi-mac-rex', 1, true), 'names host: ' .. warns[1])
    T.ok(warns[1]:find('Error: action failed', 1, true), 'names error: ' .. warns[1])
  end)

  it('no local spec for the choice (arc on Linux) -> vim.ui.open', function()
    H.in_rex()
    H.remote_world({ do_code = 1 })
    set_os('linux')
    pick('arc')
    setup(vim.tbl_extend('force', routed, { browsers = { 'firefox', 'arc' } }))
    LazyUrl.open('https://example.com')
    T.ok(T.wait_for(function()
      return #T.calls.ui_open > 0
    end))
    T.eq({ 'https://example.com' }, T.calls.ui_open)
    T.eq({}, H.local_calls())
  end)

  it('URL result falls back to a local open of the same result', function()
    H.in_rex()
    H.remote_world({ do_code = 1 })
    set_os('mac')
    setup(vim.tbl_extend('force', routed, { custom = { discord_handler('Discord') } }))
    LazyUrl.open(URL)
    T.ok(T.wait_for(function()
      return #H.local_calls() > 0
    end))
    T.eq({ { 'open', '-a', 'Discord', 'discord://discord.com/channels/1' } }, H.local_calls())
  end)

  it('discovery failures fall back silently', function()
    H.in_rex()
    H.remote_world({ actions = {} })
    setup(routed)
    LazyUrl.open('https://example.com')
    T.ok(T.wait_for(function()
      return #T.calls.ui_open > 0
    end))
    T.eq({}, T.calls.notify)
  end)
end)

describe('4.4 public API', function()
  it('LazyUrl.rex.reset() is reachable via the lazy loader', function()
    local lazy = require('lazy-url')
    T.eq('function', type(lazy.rex.reset))
    lazy.rex.reset()
  end)

  it('open() returns true once a routed dispatch is scheduled', function()
    H.in_rex()
    H.remote_world()
    setup(routed)
    T.eq(true, LazyUrl.open('https://example.com'))
    -- nothing has been sent synchronously; the callback is scheduled
    T.eq(nil, H.sent())
    T.ok(T.wait_for(function()
      return H.sent() ~= nil
    end))
  end)

  it('smart_open() returns true for a URL under the cursor (routed)', function()
    H.in_rex()
    H.remote_world()
    setup(routed)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'see https://example.com/x here' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    T.eq(true, LazyUrl.smart_open())
    T.ok(T.wait_for(function()
      return H.sent() ~= nil
    end))
    T.eq({ url = 'https://example.com/x' }, H.sent().args)
  end)

  it('smart_open() / open() return true locally too', function()
    setup({})
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'https://example.com' })
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    T.eq(true, LazyUrl.smart_open())
    T.eq(true, LazyUrl.open('https://example.com'))
    T.eq({ 'https://example.com', 'https://example.com' }, T.calls.ui_open)
  end)
end)
