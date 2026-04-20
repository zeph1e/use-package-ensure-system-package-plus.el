# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`use-package-ensure-system-package+` is a local Emacs plugin that enhances `use-package-ensure-system-package` by serializing system package installations into a sequential queue. Without it, multiple `:ensure-system-package` declarations can trigger concurrent `async-shell-command` calls (e.g., several `apt install` or `npm install` processes at once), which causes race conditions on a fresh environment.

## How It Works

The plugin advises `use-package-ensure-system-package-consify` (`:filter-return`) to replace the stock `async-shell-command` with `upesp+:async-shell-command`. The replacement:

1. Appends each install command to `upesp+:command-queue`.
2. Maintains a single persistent `/bin/bash` process (`upesp+:shell-process`) started with a custom `PS1` (`upesp_plus_prompt$ `) via `process-environment`. The process filter (`upesp+:process-filter`) routes output three ways: `sudo` password prompts are handled by `comint-watch-for-password-prompt`; the custom shell prompt sets `upesp+:command-ready t` and, when a command was executing, clears `upesp+:command-occupied` and `upesp+:command-executing`, runs `upesp+:command-executed-hook` with the completed command string, then triggers `upesp+:run-next`; all other output is ANSI-decoded via `ansi-color-apply` and inserted into the `*upesp+ installer*` buffer.
3. Commands are sent one at a time: `upesp+:send-command` checks `upesp+:command-ready` before writing to the shell via `process-send-string`. `upesp+:command-executing` is set to the command string (not just `t`) so the hook receives it. If the shell is not yet showing a prompt, it reschedules itself after 1 second.
4. Redundant installs are allowed — there is no `command-done` dedup list. `upesp+:get-package-manager` extracts just the package manager name (stripping `sudo`) from a command string or list; it is used to look up bootstrap deps, not to track history.
5. Automatically installs missing package managers before the requested package (e.g., ensures `npm` is present before running `npm install …`), driven by `upesp+:package-manager-deps`.
6. When the queue drains, `upesp+:finalize` schedules `upesp+:finalize-now` via a 10-second timer (`upesp+:shell-process-terminate-timer`). `finalize-now` kills the installer buffer and closes the shell. If new commands arrive before the timer fires, `upesp+:ensure-shell` cancels it and reuses the existing shell session.

## Load Order

The autoloads file (`use-package-ensure-system-package+-autoloads.el`) is not tracked in version control. Load the package explicitly with `(require 'use-package-ensure-system-package+)` — this must happen before any `config/*.el` file that uses `:ensure-system-package`, so place it early in `init.el` after `use-package` and `use-package-ensure-system-package` are available.

The `advice-add` call runs at require time (it is at the top level of the `.el` file), so the advice is active immediately after `require`.

## Package Manager Dependencies

Defined in `upesp+:package-manager-deps`:

| Manager | Bootstrap commands |
|---------|-------------------|
| `apt`   | _(none — assumed present)_ |
| `curl`  | `sudo apt install -y curl` |
| `npm`   | `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh \| bash` → `source ~/.nvm/nvm.sh` → `nvm install --lts` |
| `pip`   | `sudo apt install python3-pip` |

## Hooks

`upesp+:command-executed-hook` (defcustom, `(repeat function)`) — called with the completed command string as its sole argument immediately after each command finishes and before the next one is dequeued. State (`upesp+:command-occupied`, `upesp+:command-executing`) is already cleared when the hook fires, so hook functions may safely enqueue new commands or call `recursive-edit` to block.

## Modifying This Plugin

- To add a new package manager bootstrap, extend `upesp+:package-manager-deps`.
- The `.installed` sentinel in `plugins/use-package-ensure-system-package+/` prevents re-compilation on every startup. Delete it to force a rebuild after editing the `.el` file.
