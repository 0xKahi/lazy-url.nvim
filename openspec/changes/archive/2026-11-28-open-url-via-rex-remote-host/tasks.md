# Tasks

## 1. Config and test harness

- [x] 1.1 Add a minimal headless test runner (`tests/run.lua`, run with `nvim --headless -l tests/run.lua`) that loads `lua/` from the repo, provides stubs for `vim.system`, `vim.ui.open`, `vim.ui.select`, and `vim.notify`, and exits non-zero on failure. Verify that one trivial test passes and a deliberately failing one makes the command exit 1.
- [x] 1.2 Add `rex = { action = nil, host = nil }` to `config.defaults`, the `LazyUrl.Rex` class annotations, and validation in `config.validate` (each field `nil` or a non-empty string; the error names the field). Verify with tests covering valid config, `rex.action = 1`, and `rex.host = ''`.

## 2. Custom handler URL results (D7)

- [x] 2.1 Extend `match_custom` in `lua/lazy-url/open.lua` to accept `{ url = string, app? = string }` alongside `{ cmd, args }`, and report an error when the result has neither. Verify with tests for each spec scenario under "Transferable custom handler results", including invalid results.
- [x] 2.2 Implement local handling of URL results: on macOS with `app`, run `open -a <app> <url>`, otherwise call `vim.ui.open(url)`, skipping the picker. Verify with tests that check the argv passed to the `vim.system` stub and that `vim.ui.select` isn't called.

## 3. Rex resolution module (D1, D3, D4, D5)

- [x] 3.1 Create `lua/lazy-url/rex.lua` with rex binary discovery (`$REX_BIN_DIR/rex`, then `rex` on `PATH`) and an async helper that runs `rex ... --json --timeout 5s` and decodes JSON defensively. Verify with tests that a missing binary, a non-zero exit, and malformed JSON all produce "local" (nil) without raising.
- [x] 3.2 Implement `resolve(config, cb)` steps 2–3: immediate `nil` when `rex.action` is unset or `$REX_BLOCK` is empty; owner from `block inspect`; `nil` when the owner's transport is `unix`, or when it has no label and no `rex.host`. Verify with stubbed-CLI tests for "Not inside Rex", "Owning app is local", and "Owning app is remote".
- [x] 3.3 Implement host discovery (step 5): honour the `rex.host` override; otherwise read `hosts.list` and probe every host's `client ls` in parallel, choosing the first host in list order where an `app` client with the owner's label connects over `unix`. Verify with tests for "Host discovered from the owning app", "Host override", "No matching host", and "Several machines viewing the same session".
- [x] 3.4 Implement the action check (step 6) and a positive-only cache keyed by owner client id, plus `reset()`. Verify with tests that a missing action or an unreachable host returns `nil`, and that a second resolve for the same owner skips `hosts.list`, `client ls`, and `actions`.
- [x] 3.5 Implement `send(url, app, on_fail)` as `rex -S <host> do <action> --args <json> --timeout 10s`, calling `on_fail` on a non-zero exit. Verify with tests that the argv contains JSON `{"url":...}` with `app` only when given, and that `on_fail` fires on exit code 1.

## 4. Dispatch integration (D2, D6, D8)

- [x] 4.1 Route `open.open` through `rex.resolve` before dispatch. With a route, send URL results from custom handlers and run `cmd` results locally; without one, keep today's flow unchanged. Verify with tests that, with `rex.action` unset, the stubbed calls are identical to the pre-change behavior.
- [x] 4.2 When routed, build picker items from macOS specs, so browsers such as `arc` appear from a Linux host, and send the chosen item with the `app` derived per D5 (`default` or no `-a` means no `app`). Verify with tests for "Browser chosen from picker", "Default browser", "Browser override with an app name", and "Browser without an app name".
- [x] 4.3 Implement local fallback on send failure for the same choice: use the item's local spec, or `vim.ui.open` if none, and show a WARN naming the host and error. Verify with a test for "Action errors at runtime".
- [x] 4.4 Expose `LazyUrl.rex.reset()` through the lazy submodule loader and confirm that `smart_open()` and `open()` still return `true` once dispatch is scheduled. Verify with tests.

## 5. Documentation

- [x] 5.1 Add a "Remote Rex hosts" section to `README.md` covering how routing decides (owner app -> host -> action -> local fallback), the `rex.action` and `rex.host` options, and the requirement that the remote host's Rex server lists the viewing machine's server as a host. Verify that the documented config snippet passes `setup()` in a headless test.
- [x] 5.2 Document an example `init.lua` action (named `lazy_url_open` in the example) that validates that `url` has a scheme and runs `rex.exec({ 'open', '-a', app, url })` or `rex.exec({ 'open', url })`. Also document the URL-result form for custom handlers, with a `discord://` example. Verify by adding the action to a local Rex config and running `rex do lazy_url_open --args '{"url":"https://example.com"}'`, which should open the browser.

## 6. End-to-end check

- [x] 6.1 On shuffle-mac, viewed from Rex on jojo-mac, with the README action defined on jojo-mac: `LazyUrl.smart_open()` opens the URL on jojo-mac with the picked browser. After typing from shuffle-mac's own Rex app, the same keymap opens locally on shuffle-mac.
- [x] 6.2 Remove the action from jojo-mac's config (and reload). Verify that the next routed open falls back to a local open on shuffle-mac without errors. Then restore the action.
