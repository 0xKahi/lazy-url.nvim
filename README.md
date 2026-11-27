# lazy-url

A small Neovim plugin to open URLs through a configurable browser picker, with optional regex-driven custom redirects (e.g., open `discord.com` links in the Discord app).

Inspired by Neovim's built-in `gx` and the global module pattern from [snacks.nvim](https://github.com/folke/snacks.nvim).

## Requirements

- Neovim >= 0.10 (for `vim.system`, `vim.fn.getregion`, `vim.ui.open`)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  '0xKahi/lazy-url.nvim',
  keys = {
    {
      '<leader>ou',
      function()
        LazyUrl.smart_open()
      end,
      desc = '[O]pen [U]rl',
      silent = false,
      noremap = true,
      mode = { 'n', 'v' },
    },
  },
  opts = {
    browsers = { 'default', 'arc' },
    custom = {
      {
        pattern = 'discord%.com', -- Lua pattern: matches any URL containing "discord.com"
        handler = function(url)
          return {
            cmd = 'open',
            args = { (url:gsub('https://', 'discord://')) },
          }
        end,
      },
    },
  },
}
```

## Configuration

### Defaults

```lua
{
  browsers = { 'default' },
  custom = {},
  default_browser = nil,
  rex = { action = nil, host = nil }, -- see "Remote Rex hosts"
}
```

### Built-in Browser Presets

| Name      | macOS                          | Linux                | Windows         |
|-----------|--------------------------------|----------------------|-----------------|
| `default` | system default (`vim.ui.open`) | system default       | system default  |
| `brave`   | `open -a 'Brave Browser'`      | `brave-browser`      | `start brave`   |
| `firefox` | `open -a Firefox`              | `firefox`            | `start firefox` |
| `chrome`  | `open -a 'Google Chrome'`      | `google-chrome`      | `start chrome`  |
| `safari`  | `open -a Safari`               | (unsupported)        | (unsupported)   |
| `arc`     | `open -a Arc`                  | (unsupported)        | (unsupported)   |
| `dia`     | `open -a Dia`                  | (unsupported)        | (unsupported)   |
| `zen`     | `open -a 'Zen Browser'`        | `zen-browser`        | `start zen`     |
| `edge`    | `open -a 'Microsoft Edge'`     | `microsoft-edge`     | `start msedge`  |

### Overriding a preset

```lua
opts = {
  browsers = {
    'default',
    brave = { cmd = 'open', args = { '-a', '/Applications/Brave Beta.app' } },
  },
}
```

## Usage

### Public API

```lua
LazyUrl.setup(opts)        -- merge user opts; idempotent (last call wins)
LazyUrl.smart_open()       -- detect URL from cursor (normal) or visual selection, then open
LazyUrl.open(url)          -- open the given URL string directly
LazyUrl.config             -- read-only snapshot of merged config (do not mutate post-setup)
LazyUrl.rex.reset()        -- forget cached Rex host discovery (see "Remote Rex hosts")
```

```lua
require('lazy-url').setup(opts)        -- merge user opts; idempotent (last call wins)
require('lazy-url').smart_open()       -- detect URL from cursor (normal) or visual selection, then open
require('lazy-url').open(url)          -- open the given URL string directly
require('lazy-url').config             -- read-only snapshot of merged config (do not mutate post-setup)
```

Both `smart_open()` and `open(url)` return `boolean`:
- `true` — dispatch began or is scheduled (URL was valid; picker shown, command launched, or a Rex lookup is in flight)
- `false` — no URL detected (smart_open) OR empty/invalid URL (open)

### Detection chain (smart_open)

`LazyUrl.smart_open()` tries these sources in order; first match wins:

1. **Visual selection** (if mode is `v`/`V`/`<C-v>`): extract first `https?://...` from selection
2. **Markdown link**: `[label](url)` — cursor on label or URL portion
3. **Bare URL on line**: scan current line for `https?://...` under cursor column
4. **`vim.ui._get_urls()` fallback** (http/https only) — Neovim's built-in (LSP `documentLink`, extmarks, treesitter `@url`)
5. **`<cfile>` fallback** (Neovim's `isfname`-based detection)
6. None → notify WARN, return `false`

Trailing punctuation (`. , ; : ! ? )`) is stripped from detected URLs.

### Custom handlers

Custom entries are an **ordered list** (NOT a map). Iteration is deterministic; first matching pattern wins.

```lua
opts = {
  custom = {
    -- Discord links → discord:// scheme
    {
      pattern = 'discord%.com/channels/',
      handler = function(url)
        return { cmd = 'open', args = { (url:gsub('https://', 'discord://')) } }
      end,
    },
    -- Spotify links → spotify:// scheme
    {
      pattern = 'open%.spotify%.com/',
      handler = function(url)
        return { cmd = 'open', args = { (url:gsub('https://open%.spotify%.com/', 'spotify:')) } }
      end,
    },
  },
}
```

Patterns use **Lua patterns** (NOT PCRE). Highlights:
- `%.` matches a literal `.` (not `\.`)`
- `%d` matches a digit (not `\d`)
- No lookaheads, no `(?:...)`, no `\b`

Handlers receive the full URL and return one of:

- `{ cmd = string, args = string[] }` — a command run on the machine running Neovim. The `args` array must already contain the (possibly transformed) URL — the plugin passes args directly to the process.
- `{ url = string, app? = string }` — a URL to open. Locally, on macOS with `app` this runs `open -a <app> <url>`, otherwise `vim.ui.open(url)`. Unlike `cmd`, this form can be sent to another machine (see [Remote Rex hosts](#remote-rex-hosts)).

Both forms skip the browser picker. If a result has both `cmd` and `url`, `cmd` wins. A result with neither shows an error and opens nothing.

```lua
{
  pattern = 'discord%.com',
  handler = function(url)
    return { url = (url:gsub('^https://', 'discord://')), app = 'Discord' }
  end,
}
```

> ⚠️ **`gsub` gotcha — wrap it in parens.** `string.gsub` returns **two** values: the result string AND a substitution count. A table constructor captures both, so:
>
> ```lua
> args = { url:gsub('https://', 'discord://') }   -- ❌ args = { "discord://...", 1 }
> args = { (url:gsub('https://', 'discord://')) } -- ✅ args = { "discord://..." }
> ```
>
> The extra parens discard the count. Without them, `vim.system` receives the integer `1` as a positional argument and `open` interprets it as a file path relative to your cwd — producing errors like `The file /your/cwd/1 does not exist`. The plugin now validates handler args and rejects non-string entries with a clear error, but it’s still on you to discard `gsub`’s second return value.

### Examples

**Multiple browsers with explicit picker:**

```lua
opts = {
  browsers = { 'default', 'firefox', 'brave' },
}
-- pressing the keymap shows: [default, firefox, brave]
```

**Browser override (custom command):**

```lua
opts = {
  browsers = {
    'default',
    brave = { cmd = 'open', args = { '-a', '/Applications/Brave Beta.app' } },
  },
}
```

**Call `LazyUrl.open()` programmatically:**

```lua
-- from another plugin or autocmd
LazyUrl.open('https://github.com/folke/lazy.nvim')
```

## Remote Rex hosts

If you run Neovim in a Rex pane on another machine (say a session on `shuffle-mac`, viewed from the Rex app on your laptop `jojo-mac`), a normal open launches the browser on `shuffle-mac`, a screen you aren't looking at. With `rex.action` set, lazy-url sends the open to a Rex action on the machine whose Rex app you're typing from.

### How routing decides

On every open (picker choice, single browser, `default`, or custom handler URL result):

1. **Owner app.** Rex records which app owns the pane, which is the app you last typed in. If Neovim isn't in a Rex pane, or the owner app runs on the same machine as Neovim, the URL opens locally.
2. **Host.** lazy-url finds the Rex host (from `rex hosts` on Neovim's machine) whose server has the owner app connected locally, by app label. `rex.host` skips this search.
3. **Action.** The host must define `rex.action`, checked with `rex -S <host> actions`.
4. **Send.** lazy-url runs `rex -S <host> do <action> --args '{"url":"…","app":"…"}'`. Only `url` and `app` are sent.
5. **Fallback.** If any step above can't be completed, the URL opens locally without a message. If the action itself fails, the same choice opens locally with a warning.

A successful lookup is cached per owner app, so repeated opens skip steps 2–3. Run `LazyUrl.rex.reset()` after changing hosts. All Rex calls are async, so the editor never blocks.

When routed, the picker lists every browser with a macOS command, `default`, and your overrides, even if Neovim's OS has no preset for them. For example, `arc` appears from a Linux host. `app` is the argument after `-a` in the browser's macOS command, such as `Arc` or `/Applications/Brave Beta.app`. `default`, or a command without `-a`, sends no `app`. A custom handler's `{ url, app }` result is sent as-is. Its `{ cmd, args }` result always runs on Neovim's machine.

### Options

<!-- rex-config -->
```lua
opts = {
  browsers = { 'default', 'arc', 'firefox' },
  rex = {
    action = 'lazy_url_open', -- the action below; routing is off unless this is set
    -- host = 'kahi-mac-rex', -- optional: always send here, skipping discovery
  },
}
```

| Option       | Type     | Description                                                                                                  |
|--------------|----------|--------------------------------------------------------------------------------------------------------------|
| `rex.action` | `string` | Name of the Rex action to call on the viewing machine. Unset (default) disables routing entirely.            |
| `rex.host`   | `string` | Rex host label or address to send to. Use it when discovery can't work, e.g. two apps share a label.         |

### Requirements

- The `rex` CLI must be reachable from Neovim on the remote machine. lazy-url uses `$REX_BIN_DIR/rex`, which Rex panes export, and falls back to `rex` on `PATH`.
- **The remote machine's Rex server must list the viewing machine's server as a host** (`rex hosts add` on the remote machine, or via your Rex home), and `rex -S <host> actions` must work from there.
- Each viewing machine's Rex app needs a unique label (Rex app settings). Discovery matches on it.
- The action below is defined in the Rex `init.lua` of **each machine you view from**.

### The companion action

Add this to `~/.config/rex/init.lua` on each machine you view from (example for macOS):

```lua
rex.action({
  name = 'lazy_url_open',
  title = 'lazy-url: Open URL',
  description = 'Open a URL sent by lazy-url.nvim on this machine',
  args = { url = 'string', app = 'string?' },
  run = function(_, args)
    -- only URLs with a scheme (https:, discord:, ...); also stops a leading '-' reaching `open`
    if not args.url:match('^%a[%w+.-]*:') then
      error('lazy_url_open: not a URL: ' .. args.url)
    end
    local argv = args.app and { 'open', '-a', args.app, args.url } or { 'open', args.url }
    local result, err = rex.exec(argv, { timeout = 10 })
    if not (result and result.ok) then
      error('lazy_url_open: ' .. tostring(err or (result and result.stderr)))
    end
  end,
})
```

`rex.exec` runs `open` directly, with no shell, so the URL can't inject commands. An error makes `rex do` exit non-zero, and lazy-url then opens locally. To test the action on its own:

```sh
rex do lazy_url_open --args '{"url":"https://example.com"}'
rex do lazy_url_open --args '{"url":"https://example.com","app":"Arc"}'
```

### Custom handlers across machines

Return the `{ url, app? }` form so a handler's result can be sent too:

```lua
opts = {
  rex = { action = 'lazy_url_open' },
  custom = {
    {
      pattern = 'discord%.com',
      handler = function(url)
        -- sent to your machine when routed; opened locally otherwise
        return { url = (url:gsub('^https://', 'discord://')) }
      end,
    },
  },
}
```

## Comparison to Neovim's `gx`

| Feature                        | Built-in `gx`                              | `lazy-url`                          |
|--------------------------------|--------------------------------------------|-------------------------------------|
| URL detection                  | LSP / extmarks / treesitter / `<cfile>`    | same + markdown link + bare-line    |
| Browser choice                 | system default                             | configurable picker                 |
| Custom URL transforms          | no                                         | yes (Lua pattern + handler)         |
| Visual mode                    | yes                                        | yes                                 |
| Async exec                     | yes (`vim.ui.open`)                        | yes (`vim.system`)                  |
| Trailing punctuation strip     | partial (`isfname`)                        | always                              |

## Limitations (v1)

- URLs without scheme (`localhost:3000`, `example.com`) are **not** detected — explicit `http(s)://` required
- `mailto:`, `file://`, `git@`, `ssh://`, `ftp://` — not detected by the built-in chain; handle via `custom`
- Multiple URLs on the same cursor line — first match under cursor wins; no multi-URL picker
- IPv6 URLs (`http://[::1]:8080`) — not supported by the bare-URL pattern
- No `:checkhealth lazy-url` (planned for v2)
