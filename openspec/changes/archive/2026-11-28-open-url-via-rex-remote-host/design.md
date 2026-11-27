# Design

## Context

See proposal.md (Why) and specs/rex-remote-open/spec.md for the requirements.

Current dispatch (`lua/lazy-url/open.lua`) is synchronous and local: custom match -> resolve browsers for the local OS -> single launch or `vim.ui.select` picker -> `vim.system` / `vim.ui.open`. Browsers without a preset for the local OS are dropped with a warning.

Facts about Rex, verified against Rex 0.1.0-preview.25 server and CLI with a preview.37 Mac app, between jojo-mac and shuffle-mac:

- A Rex pane exports `REX_BLOCK`, `REX_SERVER`, `REX_BIN_DIR`. The server runs with launchd's PATH, so `rex` may not be on `PATH`; `$REX_BIN_DIR/rex` is reliable.
- `rex do <action>` runs the action defined in the `init.lua` of **the server it connects to**. Neither the attached app nor `-C` reroutes it. `rex -S <host> do <action>` runs it on that host's server, and `rex.exec` inside the action runs on that machine.
- Every block has an `owner` client (`rex block inspect <block> --json` -> `.block.owner`). Ownership moves to the app the user types in. The keypress that triggers lazy-url therefore makes the user's app the owner.
- `rex client inspect <id> --json` -> `.client.principal.transport` is `unix` for an app on the same machine and `tailscale` (or similar) for a remote one; `.client.info.label` is the user-set app label.
- `rex api call hosts.list` returns the current server's hosts (`label`, `endpoints`). On shuffle-mac it already lists `kahi-mac-rex` -> jojo-mac's server, and `rex -S` to it worked with no extra auth.
- `rex do` accepts `--args <json>`; `rex actions --json` lists server actions by `.actions[].name`.

## Goals / Non-Goals

**Goals:**
- Zero-config host selection for any number of viewing machines, with `rex.host` as an escape hatch.
- Never worse than today: every unknown or failure path ends in the existing local open.
- Keep the editor responsive. All Rex calls are async.

**Non-Goals:**
- Running arbitrary commands on the user's machine. Only `url` and `app` are sent.
- Using `client.url.open` or the unreleased `rex open`. They can't pick an app; revisit if Rex adds that.
- Non-macOS viewing machines in the README example. The plugin side doesn't care, but the documented action uses `open`.
- Forwarding `localhost` URLs (Rex `forward` is out of scope).

## Decisions

### D1. New module `lua/lazy-url/rex.lua` owns all Rex knowledge
`open.lua` asks `rex.resolve(config, cb)` for a route and receives either `nil` (go local) or `{ host = string, send = fun(url, app, on_fail) }`. Keeps `open.lua` focused on dispatch and makes Rex logic testable by stubbing one function.
*Alternative*: inline in `open.lua`. Rejected: it would mix async CLI plumbing into the dispatcher.

### D2. Resolve the route before dispatch, then continue in the callback
`M.open` becomes: validate -> `rex.resolve` (async; immediate `nil` when `rex.action` is unset or `$REX_BLOCK` is empty) -> existing dispatch with a `route` parameter. With a warm cache, resolution is two calls to the local server (`block inspect`, `client inspect`), which are fast. `M.open` still returns `true` once dispatch is scheduled.
*Alternative*: show the picker first and resolve in parallel. Rejected for now. It's more complex, the saving only shows up on a cold cache, and the picker contents depend on the route (D6).

### D3. Resolution pipeline (all `vim.system` async, `--json`, `--timeout 5s`)
1. `rex` binary = `$REX_BIN_DIR/rex` if executable, else `rex` if `vim.fn.executable`, else local.
2. `rex block inspect $REX_BLOCK` -> owner id. No owner -> local.
3. `rex client inspect <owner>` -> transport `unix` -> local. Missing label and no `rex.host` -> local.
4. Cache lookup by owner client id -> hit: done.
5. Host = `rex.host`, or: `rex api call hosts.list`, then for every host **in parallel** `rex -S <label> client ls`; the first host in list order with an `app` client whose `info.label` equals the owner's label and whose transport is `unix` wins.
6. `rex -S <host> actions` must contain `rex.action` -> otherwise local.
7. Cache `{ host }` under the owner id. Only positive results are cached, so adding the action or a host later works without restarting Neovim. `LazyUrl.rex.reset()` clears the cache.
*Alternative*: match the owner's Tailscale node to the host endpoint by name (`kahi-mac-m4` vs `kahi-mac-m4-rex`). Rejected: it relies on a naming convention rather than data Rex reports.

### D4. Invoke with JSON args
`rex -S <host> do <action> --args '{"url":..., "app":...}' --timeout 10s`. URLs contain `=`, `&`, and spaces, so JSON avoids KEY=VALUE splitting and quoting issues. Non-zero exit -> `on_fail`.

### D5. App name comes from the macOS command spec
For a browser item, `app` = the argument after `-a` in its macOS spec. That spec is the user's override if it has `-a`, otherwise `presets[name].mac`. `default`, or no `-a` -> omit `app`. The macOS spec is used regardless of the OS Neovim runs on, because the receiving end is the user's machine.

### D6. Picker contents depend on the route
Routed: list every configured browser that has a macOS spec or `default`, even if it has no preset for the remote host's OS. For example, `arc` is offered from a Linux host. Local: unchanged, so unknown-for-this-OS browsers are still dropped with a warning.

### D7. Custom handler result union
`match_custom` returns `{ kind = 'url', url, app? }` or `{ kind = 'cmd', cmd, args }`. Validation stays (string `cmd` / string args, or string `url` / optional string `app`). A URL result skips the picker in both modes. Routed: send it. Local: on macOS with `app` -> `open -a app url`, otherwise `vim.ui.open(url)`. A `cmd` result always runs locally (spec: Command result while routed).

### D8. Local fallback re-uses the same choice
`on_fail(err)` notifies at WARN level (`lazy-url: rex open failed (<host>): <err>; opening locally`) and runs the local path for the same item: its local command, or `vim.ui.open` if the item has no local spec on this OS. Discovery failures fall back silently. Only a failed action call, where the user expected Rex to work, produces the warning.

### D9. Config shape
`rex = { action = nil, host = nil }` in defaults; `validate` asserts both are `nil` or a non-empty string. Existing `vim.tbl_deep_extend('force', ...)` merge handles the nested table.

## Risks / Trade-offs

- [Ownership semantics change in a future Rex release] -> `rex.host` override, plus the existing local fallback.
- [Two apps share a label on different machines] -> First host in `hosts.list` order wins. Document that labels should be unique, or set `rex.host`.
- [Cold-cache latency with many or unreachable hosts] -> Host probes run in parallel with `--timeout 5s`. Only positive results are cached, so a broken setup pays this on every open; acceptable because it then opens locally.
- [The user's action runs `open -a` with input from a remote host] -> The contract carries only `url` and `app`. The README example passes them as separate argv entries via `rex.exec` (no shell) and rejects URLs without a scheme.
- [Rex CLI output shape changes (preview software)] -> JSON decoding is defensive: missing fields mean "go local", never an error.

## Migration Plan

Additive and opt-in. Without `rex.action`, behavior is unchanged. Rollback: remove `rex` from the config.

## Open Questions

- Should negative discovery results be cached briefly to avoid repeated probes on a host without the action? Deferred until real-world latency is measured. It doesn't affect the specs or tasks.
