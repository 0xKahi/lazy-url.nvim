local H = require('helpers')

local cfg = { rex = { action = 'lazy_url_open' } }

describe('rex 3.1 binary + defensive CLI', function()
  it('prefers $REX_BIN_DIR/rex', function()
    vim.env.REX_BIN_DIR = H.bin_dir
    T.eq(H.bin, require('lazy-url.rex').bin())
  end)

  it('missing binary -> local, without running anything', function()
    vim.env.REX_BLOCK = 'block:1'
    vim.env.REX_BIN_DIR = '/nonexistent'
    vim.env.PATH = '/nonexistent'
    T.eq(nil, H.resolve(cfg))
    T.eq({}, T.calls.system)
    T.eq({}, T.calls.notify)
  end)

  it('non-zero exit -> local', function()
    H.in_rex()
    T.system_handler = function()
      return { code = 1, stderr = 'boom' }
    end
    T.eq(nil, H.resolve(cfg))
    T.eq({}, T.calls.notify)
  end)

  it('malformed JSON -> local', function()
    H.in_rex()
    T.system_handler = function()
      return { stdout = '{not json' }
    end
    T.eq(nil, H.resolve(cfg))
  end)

  it('JSON of the wrong shape -> local', function()
    H.in_rex()
    T.system_handler = function()
      return { stdout = '[1,2,3]' }
    end
    T.eq(nil, H.resolve(cfg))
    T.system_handler = function()
      return { stdout = '{"block":"oops"}' }
    end
    T.eq(nil, H.resolve(cfg))
  end)

  it('spawn failure (vim.system raises) -> local', function()
    H.in_rex()
    T.system_handler = function()
      error('ENOENT')
    end
    T.eq(nil, H.resolve(cfg))
  end)

  it('lookups pass --json --timeout 5s, but api call gets no --json', function()
    H.in_rex()
    H.remote_world()
    H.resolve(cfg)
    local calls = H.rex_calls()
    T.eq({ 'block', 'inspect', 'block:1', '--json', '--timeout', '5s' }, calls[1])
    T.eq({ 'api', 'call', 'hosts.list', '--timeout', '5s' }, calls[3])
    T.eq({ '-S', 'kahi-mac-rex', 'client', 'ls', '--json', '--timeout', '5s' }, calls[4])
  end)
end)

describe('rex 3.2 resolve: in Rex? owner remote?', function()
  it('Not inside Rex: no REX_BLOCK -> nil immediately, no CLI calls', function()
    vim.env.REX_BLOCK = nil
    vim.env.REX_BIN_DIR = H.bin_dir
    H.remote_world()
    local sync, route = false, 'unset'
    require('lazy-url.rex').resolve(cfg, function(r)
      sync, route = true, r
    end)
    T.ok(sync, 'expected synchronous callback')
    T.eq(nil, route)
    T.eq({}, T.calls.system)
  end)

  it('rex.action unset -> nil immediately, no CLI calls', function()
    H.in_rex()
    H.remote_world()
    local sync = false
    require('lazy-url.rex').resolve({ rex = {} }, function(r)
      sync = true
      T.eq(nil, r)
    end)
    T.ok(sync)
    T.eq({}, T.calls.system)
  end)

  it('Owning app is local (transport unix) -> nil', function()
    H.in_rex()
    H.remote_world({ owner_transport = 'unix' })
    T.eq(nil, H.resolve(cfg))
    T.eq(2, #H.rex_calls()) -- block inspect + client inspect only
  end)

  it('no owner -> nil', function()
    H.in_rex()
    H.remote_world({ owner = false })
    T.eq(nil, H.resolve(cfg))
  end)

  it('remote owner without label and no rex.host -> nil', function()
    H.in_rex()
    H.remote_world().owner_label = nil
    T.eq(nil, H.resolve(cfg))
    T.eq(2, #H.rex_calls())
  end)

  it('remote owner without label but rex.host set -> routed', function()
    H.in_rex()
    H.remote_world().owner_label = nil
    local route = H.resolve({ rex = { action = 'lazy_url_open', host = 'kahi-mac-rex' } })
    T.eq('kahi-mac-rex', route and route.host)
  end)

  it('Owning app is remote -> route', function()
    H.in_rex()
    H.remote_world()
    local route = H.resolve(cfg)
    T.ok(route, 'expected a route')
    T.eq('kahi-mac-rex', route.host)
  end)
end)

describe('rex 3.3 host discovery', function()
  it('Host discovered from the owning app', function()
    H.in_rex()
    H.remote_world({
      hosts = { 'shuffle-mac', 'kahi-mac-rex' },
      clients = {
        ['shuffle-mac'] = { H.app('jojo-mac', 'tailscale'), H.app('shuffle-mac', 'unix') },
        ['kahi-mac-rex'] = { H.app('jojo-mac', 'unix') },
      },
    })
    T.eq('kahi-mac-rex', H.resolve(cfg).host)
  end)

  it('Host override: no hosts.list / client ls', function()
    H.in_rex()
    H.remote_world()
    local route = H.resolve({ rex = { action = 'lazy_url_open', host = 'kahi-mac-rex' } })
    T.eq('kahi-mac-rex', route.host)
    for _, a in ipairs(H.rex_calls()) do
      T.ok(a[1] ~= 'api' and a[3] ~= 'client' or a[4] ~= 'ls', 'unexpected discovery call ' .. vim.inspect(a))
    end
  end)

  it('No matching host -> nil', function()
    H.in_rex()
    H.remote_world({
      hosts = { 'a', 'b' },
      clients = { a = { H.app('other', 'unix') }, b = { H.app('jojo-mac', 'tailscale') } },
    })
    T.eq(nil, H.resolve(cfg))
  end)

  it('empty host list -> nil', function()
    H.in_rex()
    H.remote_world({ hosts = {} })
    T.eq(nil, H.resolve(cfg))
  end)

  it('ignores non-app clients with the same label', function()
    H.in_rex()
    local cli = H.app('jojo-mac', 'unix')
    cli.info.kind = 'cli'
    H.remote_world({ clients = { ['kahi-mac-rex'] = { cli } } })
    T.eq(nil, H.resolve(cfg))
  end)

  it('probes all hosts in parallel and picks the first match in list order', function()
    H.in_rex()
    H.remote_world({
      hosts = { 'down', 'first', 'second' },
      unreachable = { down = true },
      clients = { first = { H.app('jojo-mac', 'unix') }, second = { H.app('jojo-mac', 'unix') } },
      actions = { first = { 'lazy_url_open' }, second = { 'lazy_url_open' } },
    })
    T.eq('first', H.resolve(cfg).host)
    local probed = {}
    for _, a in ipairs(H.rex_calls()) do
      if a[3] == 'client' and a[4] == 'ls' then
        probed[#probed + 1] = a[2]
      end
    end
    T.eq({ 'down', 'first', 'second' }, probed)
  end)

  it('Several machines viewing the same session: owner decides the host', function()
    H.in_rex()
    local w = H.remote_world({
      owner = 'client:other',
      owner_label = 'other-mac',
      hosts = { 'kahi-mac-rex', 'other-rex' },
      clients = {
        ['kahi-mac-rex'] = { H.app('jojo-mac', 'unix') },
        ['other-rex'] = { H.app('other-mac', 'unix') },
      },
      actions = { ['kahi-mac-rex'] = { 'lazy_url_open' }, ['other-rex'] = { 'lazy_url_open' } },
    })
    T.eq('other-rex', H.resolve(cfg).host)
    -- ownership moves to jojo-mac
    w.owner, w.owner_label = 'client:jojo', 'jojo-mac'
    T.eq('kahi-mac-rex', H.resolve(cfg).host)
  end)
end)

describe('rex 3.4 action check + cache', function()
  it('Action missing on target host -> nil', function()
    H.in_rex()
    H.remote_world({ actions = { ['kahi-mac-rex'] = { 'something_else' } } })
    T.eq(nil, H.resolve(cfg))
  end)

  it('Target host unreachable -> nil', function()
    H.in_rex()
    H.remote_world({ unreachable = { ['kahi-mac-rex'] = true } })
    T.eq(nil, H.resolve(cfg))
    H.remote_world({ unreachable = { ['kahi-mac-rex'] = true } })
    T.eq(nil, H.resolve({ rex = { action = 'lazy_url_open', host = 'kahi-mac-rex' } }))
  end)

  it('Repeated opens: second resolve skips hosts.list, client ls, actions', function()
    H.in_rex()
    H.remote_world()
    T.ok(H.resolve(cfg))
    T.calls.system = {}
    local route = H.resolve(cfg)
    T.eq('kahi-mac-rex', route.host)
    T.eq({
      { 'block', 'inspect', 'block:1', '--json', '--timeout', '5s' },
      { 'client', 'inspect', 'client:owner', '--json', '--timeout', '5s' },
    }, H.rex_calls())
  end)

  it('negative results are not cached', function()
    H.in_rex()
    local w = H.remote_world({ actions = {} })
    T.eq(nil, H.resolve(cfg))
    w.actions = { ['kahi-mac-rex'] = { 'lazy_url_open' } }
    T.eq('kahi-mac-rex', H.resolve(cfg).host)
  end)

  it('reset() clears the cache', function()
    H.in_rex()
    H.remote_world()
    H.resolve(cfg)
    require('lazy-url.rex').reset()
    T.calls.system = {}
    H.resolve(cfg)
    T.ok(#H.rex_calls() > 2, 'expected full discovery after reset')
  end)

  it('cache is not reused when rex.action changes', function()
    H.in_rex()
    H.remote_world()
    H.resolve(cfg)
    T.eq(nil, H.resolve({ rex = { action = 'other_action' } }))
  end)
end)

describe('rex 3.5 send', function()
  local function route()
    H.in_rex()
    H.remote_world()
    return H.resolve(cfg)
  end

  it('invokes the action with JSON url, no app when not given', function()
    local r = route()
    r.send('https://example.com/a?b=1&c=d e', nil, function()
      error('should not fail')
    end)
    T.flush()
    local s = H.sent()
    T.eq('kahi-mac-rex', s.host)
    T.eq('lazy_url_open', s.action)
    T.eq({ url = 'https://example.com/a?b=1&c=d e' }, s.args)
    T.eq({ '--timeout', '10s' }, vim.list_slice(s.argv, #s.argv - 1))
  end)

  it('includes app when given', function()
    local r = route()
    r.send('https://example.com', 'Arc', function() end)
    T.flush()
    T.eq({ url = 'https://example.com', app = 'Arc' }, H.sent().args)
  end)

  it('on_fail fires on exit code 1 with the error text', function()
    H.in_rex()
    H.remote_world({ do_code = 1 })
    local r = H.resolve(cfg)
    local err
    r.send('https://example.com', nil, function(e)
      err = e
    end)
    T.ok(T.wait_for(function()
      return err ~= nil
    end))
    T.eq('Error: action failed', err)
  end)
end)
