# rex-remote-open Specification

## Purpose

Lets lazy-url open URLs on the machine the user is actually looking at when Neovim runs in a Rex pane on a remote host, by handing the open to a user-defined Rex action on that machine, and falling back to local opening whenever that is not possible.

## Requirements

### Requirement: Rex routing is opt-in
Rex routing SHALL be active only when the user configures `rex.action` with a non-empty action name. When it is not configured, every open SHALL behave exactly as it does without this capability.

#### Scenario: No rex config
- **WHEN** the user has not set `rex.action` and opens a URL inside a Rex pane on a remote host
- **THEN** the URL is opened locally on the host running Neovim, using the existing custom-match, picker, and launch behavior

#### Scenario: Invalid rex config
- **WHEN** `setup()` receives `rex.action` or `rex.host` that is not a string
- **THEN** `setup()` raises an error naming the invalid field

### Requirement: Route only when the pane's owning app is on another machine
With `rex.action` set, an open SHALL be routed through Rex only when Neovim runs inside a Rex pane and the Rex app that owns that pane is connected from a different machine. If Neovim is not in a Rex pane, or the owning app is on the same machine, the URL SHALL open locally.

#### Scenario: Not inside Rex
- **WHEN** `rex.action` is set and Neovim is not running inside a Rex pane
- **THEN** the URL is opened locally without invoking any Rex action

#### Scenario: Owning app is local
- **WHEN** Neovim runs in a Rex pane on `shuffle-mac` and the pane is owned by the Rex app running on `shuffle-mac` itself
- **THEN** the URL is opened locally on `shuffle-mac`

#### Scenario: Owning app is remote
- **WHEN** Neovim runs in a Rex pane on `shuffle-mac` and the pane is owned by the Rex app running on `jojo-mac`
- **THEN** the open is routed through Rex toward `jojo-mac`

### Requirement: Target host discovery
When routing, the target host SHALL be `rex.host` if configured. Otherwise it SHALL be the host, among those the current Rex server knows, whose server has an app with the same label as the owning app connected locally. If no host matches, the URL SHALL open locally.

#### Scenario: Host discovered from the owning app
- **WHEN** the pane is owned by app `jojo-mac`, `rex.host` is unset, and the Rex server's hosts include `kahi-mac-rex` where an app labelled `jojo-mac` is connected locally
- **THEN** the open is sent to host `kahi-mac-rex`

#### Scenario: Host override
- **WHEN** `rex.host` is set to `kahi-mac-rex`
- **THEN** the open is sent to `kahi-mac-rex` without searching the host list

#### Scenario: No matching host
- **WHEN** no known host has a local app with the owning app's label, and `rex.host` is unset
- **THEN** the URL is opened locally

#### Scenario: Several machines viewing the same session
- **WHEN** apps on `jojo-mac` and `other-mac` are both attached to the session and the user types in Neovim from `other-mac`
- **THEN** the open is sent to `other-mac`'s host, because the pane is now owned by the app on `other-mac`

### Requirement: Action availability check
Before sending an open, the configured action SHALL be confirmed to exist on the target host. If it does not exist or the host cannot be reached, the URL SHALL open locally.

#### Scenario: Action missing on target host
- **WHEN** the target host is resolved but its Rex config defines no action named `rex.action`
- **THEN** the URL is opened locally

#### Scenario: Target host unreachable
- **WHEN** the target host does not answer within the Rex CLI's timeout
- **THEN** the URL is opened locally

### Requirement: Action invocation contract
A routed open SHALL invoke `rex.action` on the target host with argument `url` set to the URL to open and, when a specific application was chosen, argument `app` set to that application's name. No other command text SHALL be sent.

#### Scenario: Browser chosen from picker
- **WHEN** an open is routed, two or more browsers are configured, and the user picks `arc`
- **THEN** the action is invoked with `url=<url>` and `app=Arc`

#### Scenario: Default browser
- **WHEN** an open is routed and the selected browser is `default`
- **THEN** the action is invoked with `url=<url>` and no `app` argument

#### Scenario: Browser override with an app name
- **WHEN** the selected browser is a user override whose macOS command is `open -a '/Applications/Brave Beta.app'`
- **THEN** the action is invoked with `app=/Applications/Brave Beta.app`

#### Scenario: Browser without an app name
- **WHEN** the selected browser's command does not specify an application with `-a`
- **THEN** the action is invoked with `url=<url>` and no `app` argument

### Requirement: Transferable custom handler results
A custom handler SHALL be allowed to return `{ url = string, app? = string }` in addition to `{ cmd = string, args? = string[] }`. A URL result SHALL be routed when routing applies and opened locally otherwise. A command result SHALL always run locally.

#### Scenario: URL result while routed
- **WHEN** an open is routed and a handler matching `discord%.com` returns `{ url = 'discord://discord.com/channels/1' }`
- **THEN** the action is invoked with `url=discord://discord.com/channels/1` and the picker is not shown

#### Scenario: URL result while local
- **WHEN** routing does not apply and a handler returns `{ url = 'discord://discord.com/channels/1', app = 'Discord' }`
- **THEN** the URL is opened locally with the Discord application, without showing the picker

#### Scenario: Command result while routed
- **WHEN** an open would be routed and the matching handler returns `{ cmd = 'open', args = { 'discord://...' } }`
- **THEN** the command runs locally on the host running Neovim, as it does today

#### Scenario: Invalid handler result
- **WHEN** a handler returns a table with neither a string `url` nor a string `cmd`
- **THEN** an error notification is shown and nothing is opened

### Requirement: Fallback on routed failure
If invoking the action on the target host fails, the same URL and application choice SHALL be opened locally, and the user SHALL be told that the Rex open failed.

#### Scenario: Action errors at runtime
- **WHEN** the action is invoked and exits with an error
- **THEN** the URL is opened locally with the same browser choice and a warning names the Rex failure

### Requirement: Editor stays responsive
Rex lookups and action calls SHALL NOT block the editor. Discovery results SHALL be reused for later opens while the pane's owning app stays the same.

#### Scenario: Slow Rex host
- **WHEN** a routed open waits on a Rex host that takes several seconds to answer
- **THEN** the user can keep editing during the wait

#### Scenario: Repeated opens
- **WHEN** the user opens two URLs in a row from a pane whose owning app did not change
- **THEN** the second open does not repeat host discovery
