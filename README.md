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
```

```lua
require('lazy-url').setup(opts)        -- merge user opts; idempotent (last call wins)
require('lazy-url').smart_open()       -- detect URL from cursor (normal) or visual selection, then open
require('lazy-url').open(url)          -- open the given URL string directly
require('lazy-url').config             -- read-only snapshot of merged config (do not mutate post-setup)
```

Both `smart_open()` and `open(url)` return `boolean`:
- `true` — dispatch began (URL was valid; picker shown OR command launched)
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

Handlers receive the full URL and return `{ cmd = string, args = string[] }`. The `args` array must already contain the (possibly transformed) URL — the plugin passes args directly to the process.

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
