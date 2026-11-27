local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

local function readme()
  return table.concat(vim.fn.readfile(root .. '/README.md'), '\n')
end

---Evaluate a README snippet of the form `opts = { ... }` and return opts.
local function eval_opts(code)
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(load(code, 'README snippet', 't', env))
  chunk()
  return env.opts
end

describe('5.1 README', function()
  it('documented rex config passes setup()', function()
    local code = readme():match('<!%-%- rex%-config %-%->\n```lua\n(.-)\n```')
    T.ok(code, 'rex-config snippet not found')
    local opts = eval_opts(code)
    T.eq('lazy_url_open', opts.rex.action)
    local lazy = require('lazy-url')
    lazy.setup(opts)
    T.eq('lazy_url_open', lazy.config.rex.action)
  end)

  it('documented custom-handler-across-machines snippet passes setup() and returns a URL result', function()
    local section = readme():match('### Custom handlers across machines(.-)\n## ')
    local code = section and section:match('```lua\n(.-)\n```')
    T.ok(code, 'snippet not found')
    local opts = eval_opts(code)
    require('lazy-url').setup(opts)
    T.eq({ url = 'discord://discord.com/channels/1' }, opts.custom[1].handler('https://discord.com/channels/1'))
  end)
end)
