# Proposal

## Why

When Neovim runs in a Rex pane on a remote host (e.g. a Rex session on `shuffle-mac` viewed from the Rex app on `jojo-mac`), lazy-url launches the browser on the remote machine, so the page opens on a screen the user isn't looking at. Rex already knows which app the user is typing from and can run actions on that app's home server, so lazy-url can route the open back to the user's machine without per-host hard-coding.

## What Changes

- New opt-in `rex` config group: `rex = { action = '<name>', host? = '<label|address>' }`. Rex routing is enabled only when `rex.action` is set.
- When Neovim is inside a Rex pane and the app that owns that pane is on a different machine, every open (picker choice, single browser, `default`, custom handler) is sent as `rex -S <host> do <rex.action> url=<url> [app=<App>]` instead of being launched locally.
- The target host is discovered from the Rex CLI (pane owner -> owning app -> the known host where that app is a local client); `rex.host` overrides discovery.
- Any failure along the way (not in Rex, owner app is local, host not found, action not defined on the host, action call fails) falls back to today's local behavior.
- Custom handlers may additionally return a transferable form `{ url = string, app? = string }`. The existing `{ cmd, args }` form keeps working locally; in Rex mode it falls back to local because it cannot be sent to another machine.
- README documents the `rex` options and how to define the companion action in Rex's `init.lua` (runs `open -a <App> <url>` / `open <url>` on the user's machine).
- No breaking changes: without `rex.action`, behavior is identical to today.

## Capabilities

### New Capabilities

- `rex-remote-open`: Routing URL opens from Neovim running on a remote Rex host to the machine running the Rex app the user is typing from, including host discovery, the action contract, and fallback to local opening.

### Modified Capabilities

<!-- None: openspec/specs/ has no existing capabilities. -->

## Impact

- Code: `lua/lazy-url/config.lua` (new `rex` defaults, validation, types), `lua/lazy-url/open.lua` (dispatch through Rex before local exec; custom handler URL form), new `lua/lazy-url/rex.lua` (detection, host discovery, cache, invocation).
- Runtime dependency (optional): the `rex` CLI available to Neovim (via `$REX_BIN_DIR` or `PATH`) on the remote host; a user-defined action in the Rex config of each machine the user views from; Rex host entries pointing at those machines.
- Docs: `README.md` gains a "Remote Rex hosts" section with config and an `init.lua` action example.
- Platform: the action example targets macOS (`open -a`); the plugin side is OS-agnostic since it only calls the `rex` CLI.
