# CLAUDE.md

This file gives instructions to Claude Code (claude.ai/code) for work in this repository.

## Overview

`use-package-ensure-system-package+` is a local Emacs plugin. It improves `use-package-ensure-system-package`: it puts system package installs into one queue, in order.

Without this plugin, more than one `:ensure-system-package` declaration can start `async-shell-command` calls at the same time. For example, several `apt install` or `npm install` processes can run together. Running installs at the same time can cause race conditions on a new environment.

## How It Works

The plugin adds advice, of type `:filter-return`, to `use-package-ensure-system-package-consify`. This advice replaces the stock `async-shell-command` with `upesp+:async-shell-command`. The new function does this:

1. It appends each install command to `upesp+:command-queue`.
2. It keeps one persistent `/bin/bash` process, named `upesp+:shell-process`. This process starts with a custom `PS1` value, `upesp_plus_prompt$ `, set through `process-environment`.

   The process filter, `upesp+:process-filter`, sends output to three actions. First, a `sudo` password prompt makes the filter show the installer buffer and schedule a password read for later. See the Password Prompts and Cancellation section that follows. Second, the custom shell prompt sets `upesp+:command-ready` to `t`. If a command was running, the filter clears `upesp+:command-occupied`, `upesp+:command-executing`, and `upesp+:command-cancelled`. It then records the row's status (`success`, `failed`, or `cancelled`) in the queue, runs `upesp+:command-executed-hook` with the completed command string, and starts `upesp+:run-next`. Third, all other output goes through `ansi-color-apply`, for ANSI decoding, then into the `*upesp+ installer*` buffer.
3. The plugin sends commands one at a time. `upesp+:send-command` checks `upesp+:command-ready` before it writes to the shell, with `process-send-string`. `upesp+:send-command` sets `upesp+:command-executing` to the full command string, not just to `t`, so the hook can get this value. If the shell prompt is not showing yet, `upesp+:send-command` runs itself again after 1 second.
4. The plugin allows redundant installs. There is no `command-done` list to remove duplicates.

   `upesp+:get-package-manager` gets only the package manager name from a command string or list, and removes `sudo` from it. The plugin uses this name to find bootstrap dependencies, not to track history.
5. The plugin installs missing package managers automatically, before it installs the requested package. For example, it makes sure that `npm` is present before it runs `npm install`. `upesp+:package-manager-deps` controls this process.
6. When the queue is empty, `upesp+:finalize` schedules `upesp+:finalize-now`, through a timer named `upesp+:shell-process-terminate-timer`. The timer length comes from `upesp+:shell-process-expiry`, 360 seconds by default. `upesp+:finalize-now` kills the installer buffer, which also ends the shell process, and kills the queue buffer. It also resets `upesp+:queue-entries` and `upesp+:queue-next-id`. As a result, the queue starts empty for the next round of installs. If new commands arrive before the timer runs out, `upesp+:ensure-shell` cancels the timer and uses the existing shell session again.

## Queue Buffer and Installer Buffer

The plugin gives each queued command its own row, in the struct `upesp+:queue-entry`. Each entry holds these fields: `id`, `cmd`, `label`, `pkgmgr`, `status`, and `marker`. The `status` field takes one of five values: `waiting`, `installing`, `success`, `failed`, or `cancelled`.

The queue buffer, `*upesp+ queue*`, shows one row for each entry, in a `tabulated-list-mode` buffer (`upesp+:queue-mode`). The columns are Command, Package Manager, and Status.

`upesp+:status-face` gives each status a face:

- `waiting`: the row has no marker yet, so the row gets the `shadow` face, not a status face.
- `installing`: the `bold` face.
- `success`: the `success` face, green in the default theme.
- `failed`: the `error` face, red in the default theme.
- `cancelled`: the plain face. This status is a record, not a result that needs a warning color.

The installer buffer, renamed for the running command through `upesp+:installer-buffer-name`, keeps every command's output for the whole session. It does not clear between commands. A dashed line separates each command's section from the one before it. `upesp+:finalize-now` is the only function that clears this buffer, when it kills the buffer at the end of a session.

Each command's `"Executing command"` line uses the `bold` face. Each result line, for example `"Command succeeded (exit code 0): ..."`, uses the same face as the row's status.

`upesp+:send-command` records a buffer marker at the start of each command's log line, through `upesp+:queue-set-marker`. The queue buffer's `RET` key, bound to `upesp+:queue-jump-to-command`, uses this marker to jump straight to that command's log. A `waiting` row has no marker yet, so `RET` on that row only shows a message.

`upesp+:queue-mode-map` gives the queue buffer these keys:

- `q`: buries the buffer.
- `n` / `p`: move to the next or previous row.
- `RET`: jumps to the selected row's log, in the installer buffer.
- `r` (`upesp+:queue-restart-command`): resubmits a `cancelled` or `failed` row's command as a new row, through `upesp+:async-shell-command`.
- `k` (`upesp+:queue-kill-command`): interrupts the row that is currently `installing`.

## Password Prompts and Cancellation

`upesp+:process-filter` checks output against two patterns to find a password prompt: the built-in `comint-password-prompt-regexp`, and `upesp+:extra-password-prompt-regexp`. The extra pattern exists because some newer distributions, for example Ubuntu 26.04 with sudo-rs, show a bracketed prompt like `[sudo: authenticate] Password: ` instead of the classic `[sudo] password for USER: `. `comint-password-prompt-regexp` requires its own `[sudo]` keyword, or a bare password word, right at the start of the chunk, so the extra `[sudo: ...]` prefix defeats it. If a future prompt format still slips through both patterns, extend `upesp+:extra-password-prompt-regexp` rather than replace it, so the classic and bracketed forms both keep matching.

When output matches a password prompt, `upesp+:process-filter` shows the installer buffer and inserts the raw prompt text. It does not read the password itself. Instead, it schedules `upesp+:ask-password` on a timer, with `run-with-timer 0`.

The plugin needs this timer for one reason: quitting. Emacs inhibits quitting for a process filter's whole run. As a result, a stray C-g mid-filter cannot leave process state or buffer state half-updated. A `read-passwd` call made directly inside the filter runs inside that inhibited state. There, C-g cannot raise `quit`. `with-local-quit` does not fix this. It catches the quit itself and only sets `quit-flag` again, instead of raising the quit back to the caller. A timer callback runs from the normal command loop, outside the inhibited state. There, C-g at `read-passwd` works like it does at any other prompt.

`upesp+:ask-password` reads the password and sends it to the process, with a trailing newline. If the user cancels the read with C-g, `upesp+:ask-password` sends an interrupt byte, `\C-c`, to the process instead, and sets `upesp+:command-cancelled` to `t`.

`upesp+:queue-kill-command`, the queue buffer's `k` key, uses this same path. It sets `upesp+:command-cancelled` to `t` and sends the same interrupt byte, for the row that is currently `installing`.

The exit-code branch of `upesp+:process-filter` reads `upesp+:command-cancelled`. When this flag is `t`, the branch records the command's status as `cancelled`, not `success` or `failed`, then resets the flag to `nil`.

## Load Order

Git does not track the autoloads file, `use-package-ensure-system-package+-autoloads.el`.

Load the package with `(require 'use-package-ensure-system-package+)`. Do this before any `config/*.el` file that uses `:ensure-system-package`. In `init.el`, place this `require` call early, right after `use-package` and `use-package-ensure-system-package` become available.

The `advice-add` call runs at require time, at the top level of the `.el` file. As a result, the advice becomes active right after `require` runs.

## Package Manager Dependencies

`upesp+:package-manager-deps` defines these bootstrap commands:

| Manager | Bootstrap commands |
|---------|-------------------|
| `apt`   | None. The plugin assumes `apt` is already present. |
| `curl`  | `sudo apt install -y curl` |
| `npm`   | `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh \| bash` → `source ~/.nvm/nvm.sh` → `nvm install --lts` |
| `pip`   | `sudo apt install python3-pip` |

## Hooks

`upesp+:command-executed-hook` is a `defcustom`, of type `(repeat function)`. The plugin calls this hook right after each command finishes, and before it takes the next command from the queue. The hook gets one argument: the completed command string.

When the hook runs, the plugin has already cleared the state variables `upesp+:command-occupied` and `upesp+:command-executing`. As a result, a hook function can safely add new commands to the queue, or call `recursive-edit` to pause the plugin.

The hook also runs for a `cancelled` command, with the same one argument, the command string. The hook does not get the status. To read a command's status, read the `status` field of its entry in `upesp+:queue-entries` after the hook runs.

## Modifying This Plugin

- To add a new package manager bootstrap, add an entry to `upesp+:package-manager-deps`.
- To change how a status looks, edit `upesp+:status-face`.
- To recognize a new password prompt format, extend `upesp+:extra-password-prompt-regexp` instead of replacing it, so older formats keep matching too.
- The `.installed` sentinel file, in `plugins/use-package-ensure-system-package+/`, stops recompilation on every startup. After you edit the `.el` file, delete this sentinel file to force a rebuild.
