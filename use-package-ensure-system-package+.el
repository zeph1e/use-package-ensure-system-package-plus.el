;;; use-package-ensure-system-package+.el  -*- lexical-binding: t; -*-

;; Written by Yunsik Jang <z3ph1e@gmail.com>
;; You can use, modify, and redistribute this file freely.

;; This changes the behavior of system package installs from
;; `use-package-ensure-system-package'. It runs all installs through one
;; persistent shell session. As a result, `sudo' prompts for a password
;; only once.

(require 'use-package)
(require 'use-package-ensure-system-package)
(require 'cl-lib)
(require 'comint)
(require 'ansi-color)
(require 'tabulated-list)

(defvar upesp+:command-queue nil
  "Queue of (ID . COMMAND) pairs to run sequentially.")

(defvar upesp+:package-manager-bootstrapped nil
  "List of package managers whose bootstrap commands have been enqueued.")

(defvar upesp+:command-occupied nil
  "Non-nil while waiting for the current command to finish.")

(defvar upesp+:command-ready nil
  "Non-nil when shell is showing prompt.")

(defvar upesp+:command-executing nil
  "Non-nil when executing command in shell.")

(defvar upesp+:command-executing-id nil
  "Id of the queue entry for the command currently executing.
Kept separate from `upesp+:command-executing' (which holds the raw command
string) because that variable's contents are a public contract relied on by
`upesp+:command-executed-hook' consumers (see config/vterm.el) and must not
change shape.")

(defvar upesp+:command-cancelled nil
  "Non-nil when the currently executing command was interrupted via C-g
at a password prompt. Read once by the exit-code branch of
`upesp+:process-filter' to record `'cancelled' instead of `'success'/`'failed',
then reset to nil.")

(defcustom upesp+:package-manager-deps
  `(("apt" . nil)
    ("curl" . ("sudo apt install -y curl"))
    ("npm" . ("curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash"
              "source ~/.nvm/nvm.sh"
              "nvm install --lts"))
    ("pip" . ("sudo apt install python3-pip")))
  "Bootstrap commands needed before a package manager can be used."
  :group 'upesp+
  :type 'alist)

;;; Shared shell process

(defvar upesp+:shell-process nil
  "The single persistent shell process used for all installs.")

(defcustom upesp+:shell-process-expiry 360
  "Timeout for the installer shell-process termination."
  :group 'upesp+
  :type 'integer)

(defvar upesp+:shell-process-terminate-timer nil
  "Timer handle for shell-process termination.")

(defconst upesp+:shell-buffer "*upesp+ installer*")

(defconst upesp+:shell-prompt "upesp_plus_prompt:$?$ "
  "PS1 for the installer shell.
`$?' is bash's own previous-exit-status parameter, expanded fresh by bash
each time the prompt is displayed (`promptvars' defaults to on for any
interactive shell, and interactivity here comes from the pty, not from
--norc/--noprofile, which only skip startup files) — the literal text
ending up in the shell's output is e.g. \"upesp_plus_prompt:0$ \" or
\"upesp_plus_prompt:127$ \".")

(defconst upesp+:shell-prompt-regexp
  (concat (regexp-quote "upesp_plus_prompt:")
          "\\([0-9]+\\)"
          (regexp-quote "$ "))
  "Matches a displayed shell prompt; group 1 is the previous exit status.")

(defcustom upesp+:command-executed-hook nil
  "Hook run when a command was executed."
  :group 'upesp+
  :type '(repeat function))

;;; Installation queue status buffer

(cl-defstruct upesp+:queue-entry
  ;; status: 'waiting / 'installing / 'success / 'failed / 'cancelled
  ;; marker: nil until the command's log starts
  id cmd label pkgmgr status marker)

(defvar upesp+:queue-entries nil
  "All queue rows for this session, newest first.
Entries are never removed except by `upesp+:finalize-now', which clears
this when the installer/queue buffers themselves are killed.")

(defvar upesp+:queue-next-id 0
  "Counter for unique queue-entry ids.
The same command string can be queued more than once, so the id (not the
command text) is what uniquely keys a row.")

(defconst upesp+:queue-buffer "*upesp+ queue*")

(defconst upesp+:installer-label-max-len 40
  "Max length for a package label used in the installer buffer's name.")


(defun upesp+:command-tokens (command)
  "Return COMMAND (a string or a list) as tokens with a leading sudo stripped."
  (let ((tokens (if (stringp command)
                     (split-string-shell-command command)
                   command)))
    (if (and tokens (stringp (car tokens)) (string= (car tokens) "sudo"))
        (cdr tokens)
      tokens)))

(defun upesp+:get-package-manager (command)
  (car (upesp+:command-tokens command)))

(defun upesp+:sanitize-label (text &optional max-len)
  "Collapse whitespace and drop asterisks in TEXT, truncating to MAX-LEN."
  (let ((flat (string-trim
               (replace-regexp-in-string
                "\\*" ""
                (replace-regexp-in-string "[ \t\n\r]+" " " text)))))
    (if (and max-len (> (length flat) max-len))
        (concat (substring flat 0 (max 0 (- max-len 3))) "...")
      flat)))

(defun upesp+:extract-package-label (command &optional max-len)
  "Best-effort package name for COMMAND, MAX-LEN chars long.
Falls back to the raw command text (via `upesp+:sanitize-label') when no
clear \"install\" argument is found, e.g. for a bootstrap command like a
curl|bash pipeline that has no package name at all."
  (let* ((raw (if (stringp command) command (mapconcat #'identity command " ")))
         (tokens (upesp+:command-tokens command))
         (install-pos (cl-position "install" tokens :test #'string-equal))
         (args (and install-pos
                    (cl-remove-if (lambda (tok) (string-prefix-p "-" tok))
                                  (nthcdr (1+ install-pos) tokens))))
         (label (and args (mapconcat #'identity args " "))))
    (upesp+:sanitize-label
     (if (and label (not (string-empty-p label))) label raw)
     max-len)))

(defun upesp+:installer-buffer-name (cmd)
  (format "*upesp+ installer: %s*"
          (upesp+:extract-package-label cmd upesp+:installer-label-max-len)))

(defun upesp+:get-package-manager-deps (package-manager)
  (unless (or (member package-manager upesp+:package-manager-bootstrapped)
              (and (stringp package-manager) (executable-find package-manager)))
    (cdr (assoc package-manager upesp+:package-manager-deps))))

(defun upesp+:shell-live-p ()
  (and upesp+:shell-process (process-live-p upesp+:shell-process)))

(defvar upesp+:queue-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") 'bury-buffer)
    (define-key map (kbd "n") 'next-line)
    (define-key map (kbd "p") 'previous-line)
    (define-key map (kbd "r") 'upesp+:queue-restart-command)
    (define-key map (kbd "k") 'upesp+:queue-kill-command)
    (define-key map (kbd "RET") 'upesp+:queue-jump-to-command)
    map)
  "Keymap for `upesp+:queue-mode'.")

(define-derived-mode upesp+:queue-mode tabulated-list-mode "UPESP+ Queue"
  "Major mode listing every install command queued this session."
  (setq tabulated-list-format
        [("Command" 50 t) ("Package Manager" 16 t) ("Status" 12 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key nil)
  (tabulated-list-init-header))

(defun upesp+:queue-jump-to-command ()
  "Jump to where the selected row's command starts, in the installer
buffer. The installer buffer is not shown automatically (see
`upesp+:process-filter'), so this is the only way to see a running or
already-finished command's output. If the command has not started yet
(no log recorded), just message — there is nothing to jump to."
  (interactive)
  (let* ((id (tabulated-list-get-id))
         (entry (and id (cl-find id upesp+:queue-entries
                                  :key #'upesp+:queue-entry-id)))
         (marker (and entry (upesp+:queue-entry-marker entry))))
    (cond
     ((null entry) (message "upesp+: no command selected"))
     ((null marker) (message "upesp+: command has not started yet"))
     ((not (buffer-live-p (marker-buffer marker)))
      (message "upesp+: installer buffer no longer exists"))
     (t
      (let ((win (display-buffer (marker-buffer marker)
                                  '(display-buffer-pop-up-window))))
        (when win
          (set-window-point win marker)
          (select-window win)))))))

(defun upesp+:queue-restart-command ()
  "Re-submit the selected queue row's command as a new row.
Only a `'cancelled' or `'failed' row can be restarted."
  (interactive)
  (let* ((id (tabulated-list-get-id))
         (entry (and id (cl-find id upesp+:queue-entries
                                  :key #'upesp+:queue-entry-id))))
    (cond
     ((null entry) (message "upesp+: no command selected"))
     ((not (memq (upesp+:queue-entry-status entry) '(cancelled failed)))
      (message "upesp+: only a cancelled or failed command can be restarted"))
     (t
      (upesp+:async-shell-command (upesp+:queue-entry-cmd entry))
      (message "upesp+: re-queued %s" (upesp+:queue-entry-label entry))))))

(defun upesp+:queue-kill-command ()
  "Interrupt the selected row's command if it is the one currently installing.
Reuses the same interrupt-and-mark-cancelled path as a C-g at a password
prompt (see `upesp+:ask-password'): sends an interrupt byte to the shared
shell and sets `upesp+:command-cancelled', so the exit-code branch of
`upesp+:process-filter' records the row as `'cancelled' once the shell's
own prompt reappears."
  (interactive)
  (let* ((id (tabulated-list-get-id))
         (entry (and id (cl-find id upesp+:queue-entries
                                  :key #'upesp+:queue-entry-id))))
    (cond
     ((null entry) (message "upesp+: no command selected"))
     ((not (eq (upesp+:queue-entry-status entry) 'installing))
      (message "upesp+: only the currently installing command can be killed"))
     ((not (upesp+:shell-live-p))
      (message "upesp+: no running shell to interrupt"))
     (t
      (setq upesp+:command-cancelled t)
      (process-send-string upesp+:shell-process "\C-c")
      (message "upesp+: interrupting %s" (upesp+:queue-entry-label entry))))))

(defvar upesp+:installer-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") 'bury-buffer)
    map)
  "Keymap for `upesp+:installer-mode'.")

(define-derived-mode upesp+:installer-mode special-mode "UPESP+ Installer"
  "Major mode for the shared installer output buffer.")

(defun upesp+:queue-buffer-get-create ()
  (or (get-buffer upesp+:queue-buffer)
      (with-current-buffer (get-buffer-create upesp+:queue-buffer)
        (upesp+:queue-mode)
        (current-buffer))))

(defun upesp+:queue-row-cell (text face)
  "Propertize TEXT with FACE, or return it plain when FACE is nil."
  (if face (propertize text 'face face) text))

(defun upesp+:status-face (status)
  "Face for STATUS (`'installing'/`'success'/`'failed'/`'cancelled'), or nil
for the plain face. Shared by the queue buffer's rows and the installer
buffer's own \"Executing command\"/result lines, so both agree on what
each status looks like. `'cancelled' gets no distinct face — it is not a
normal outcome to draw attention to, just a record."
  (cond
   ((eq status 'installing) 'bold)
   ((eq status 'success) 'success)
   ((eq status 'failed) 'error)))

(defun upesp+:queue-status-face (entry)
  "Return the face to render ENTRY's row in, or nil for the plain face.
No marker means the command never started, which takes priority over
status (`'waiting' always has no marker)."
  (if (null (upesp+:queue-entry-marker entry))
      'shadow
    (upesp+:status-face (upesp+:queue-entry-status entry))))

(defun upesp+:queue-entry->row (entry)
  (let ((face (upesp+:queue-status-face entry)))
    (list (upesp+:queue-entry-id entry)
          (vector (upesp+:queue-row-cell
                   (upesp+:queue-entry-label entry) face)
                  (upesp+:queue-row-cell
                   (or (upesp+:queue-entry-pkgmgr entry) "") face)
                  (upesp+:queue-row-cell
                   (symbol-name (upesp+:queue-entry-status entry)) face)))))

(defun upesp+:queue-buffer-refresh ()
  (with-current-buffer (upesp+:queue-buffer-get-create)
    (setq tabulated-list-entries
          (mapcar #'upesp+:queue-entry->row (reverse upesp+:queue-entries)))
    (tabulated-list-print t)))

(defun upesp+:queue-buffer-popup ()
  (let ((buf (upesp+:queue-buffer-get-create)))
    (unless (get-buffer-window buf)
      (when-let ((win (display-buffer buf '(display-buffer-pop-up-window))))
        ;; Without this, a later `display-buffer-pop-up-window' call for
        ;; another buffer can take this new window instead. For example,
        ;; `upesp+:queue-jump-to-command' pops up the installer buffer this
        ;; way. This removes the queue buffer from its window right after
        ;; the buffer appears.
        (set-window-dedicated-p win t)))))

(defun upesp+:queue-enqueue (cmd)
  "Create a `waiting' row for CMD; return the (ID . CMD) queue item."
  (let* ((id (cl-incf upesp+:queue-next-id))
         (entry (make-upesp+:queue-entry
                 :id id :cmd cmd
                 :label (upesp+:extract-package-label cmd)
                 :pkgmgr (upesp+:get-package-manager cmd)
                 :status 'waiting)))
    (push entry upesp+:queue-entries)
    (upesp+:queue-buffer-refresh)
    (upesp+:queue-buffer-popup)
    (cons id cmd)))

(defun upesp+:queue-set-status (id status)
  (when-let ((entry (cl-find id upesp+:queue-entries
                              :key #'upesp+:queue-entry-id)))
    (setf (upesp+:queue-entry-status entry) status)
    (upesp+:queue-buffer-refresh)))

(defun upesp+:queue-set-marker (id marker)
  (when-let ((entry (cl-find id upesp+:queue-entries
                              :key #'upesp+:queue-entry-id)))
    (setf (upesp+:queue-entry-marker entry) marker)
    (upesp+:queue-buffer-refresh)))

(defun upesp+:ensure-shell ()
  "Return the shared shell process, starting a fresh one if needed."
  (if (upesp+:shell-live-p)
      (progn
        (when upesp+:shell-process-terminate-timer
          (cancel-timer upesp+:shell-process-terminate-timer)
          (setq upesp+:shell-process-terminate-timer nil))
        upesp+:shell-process)
    (let ((buf (get-buffer-create upesp+:shell-buffer)))
      (with-current-buffer buf
        (upesp+:installer-mode)
        (let ((inhibit-read-only t)) (erase-buffer)))

      (let ((process-environment `("TERM=dumb"
                                   ,(format "PS1=%s" upesp+:shell-prompt)
                                   ,@process-environment)))
        (setq upesp+:shell-process
              (make-process
               :name "upesp+-shell"
               :buffer buf
               :command '("/bin/bash" "--norc" "--noprofile")
               :filter #'upesp+:process-filter
               :sentinel #'upesp+:process-sentinel
               :noquery t
               :connection-type 'pty))))))

(defun upesp+:watch-for-shell-prompt (string)
  "Return the previous command's exit-status string if STRING contains the
shell prompt, else nil."
  (let ((case-fold-search t)
        (stripped (string-replace "\r" "" string)))
    (when (string-match upesp+:shell-prompt-regexp stripped)
      (match-string 1 stripped))))

(defun upesp+:strip-fancy-progress-bar (string)
  "Remove apt's Dpkg::Progress-Fancy status line (ESC 7 .. ESC 8).
That reporter saves the cursor (ESC 7), jumps to the terminal's last row to
draw a \"Progress: [ NN%] [bar]\" line there, then restores the cursor
\(ESC 8) to resume dpkg's real output exactly where it left off.  In a real
terminal this detour never touches the scrolling log text, so it must be
dropped whole (bar text included) rather than replayed inline: replaying
it as an overwrite only happens to work when another redraw follows, and
leaves the bar text stuck to whatever plain text comes right after the
final redraw otherwise."
  (replace-regexp-in-string "\0337\\(?:[^\033]\\|\033[^8]\\)*\0338" "" string))

(defun upesp+:normalize-cursor-escapes (string)
  "Strip terminal control sequences that `ansi-color-apply' cannot handle.
`ansi-color-apply' only understands CSI (ESC [ ...) sequences; any other
bare ESC passes through it with the ESC silently dropped and the following
character left behind as garbage text."
  (replace-regexp-in-string "\033[^[]" ""
                             (upesp+:strip-fancy-progress-bar string)))

(defun upesp+:ask-password (proc buf prompt)
  "Read a password with PROMPT and send it to PROC, followed by a newline.
Meant to run from a timer rather than from a process filter — see the call
site in `upesp+:process-filter' for why. If the read is cancelled with C-g,
interrupt PROC instead and record the cancellation on BUF's queue entry, so
the exit-code branch of `upesp+:process-filter' (which runs once PROC's own
prompt reappears after the interrupt) marks it `'cancelled'."
  (when (buffer-live-p buf)
    (condition-case nil
        (let ((pass (read-passwd prompt)))
          (when (process-live-p proc)
            (process-send-string proc (concat pass "\n")))
          (when (stringp pass) (clear-string pass)))
      (quit
       (with-current-buffer buf
         (setq upesp+:command-cancelled t)
         (let ((inhibit-read-only t))
           (goto-char (point-max))
           (insert "\n[upesp+: password entry cancelled (C-g) —\
 interrupting]\n")))
       (when (process-live-p proc)
         (process-send-string proc "\C-c"))))))

(defun upesp+:process-filter (proc output)
  (when-let ((buf (process-buffer proc)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (exit-code (upesp+:watch-for-shell-prompt output)))
        ;; The installer buffer is not shown automatically. The queue
        ;; buffer's `RET' key, `upesp+:queue-jump-to-command', is the only
        ;; way to show it. As a result, the installer buffer does not take
        ;; the window away from the queue buffer every time a command
        ;; starts. See `upesp+:queue-buffer-popup'.
        (goto-char (point-max))
        (cond ((string-match-p comint-password-prompt-regexp output)
               ;; Show the installer buffer. A password prompt always
               ;; needs the user's attention. As a result, the buffer
               ;; stays visible afterward, unlike for other output.
               (unless (get-buffer-window buf t)
                 (display-buffer buf '(display-buffer-pop-up-window)))
               (insert output)
               ;; A process filter runs with quitting inhibited (see the
               ;; Elisp manual, "Filter Functions"). If `read-passwd' runs
               ;; directly here, C-g cannot raise `quit'. Defer the read
               ;; to a zero-delay timer instead. A timer runs from the
               ;; ordinary command loop, where C-g at `read-passwd' works
               ;; like it does at any other prompt.
               (run-with-timer 0 nil #'upesp+:ask-password proc buf output))
              (exit-code
               (setq upesp+:command-ready t)
               (when upesp+:command-executing
                 (let* ((executed-cmd upesp+:command-executing)
                        (executed-id upesp+:command-executing-id)
                        (cancelled upesp+:command-cancelled)
                        (success (and (not cancelled) (string= exit-code "0")))
                        (status (cond (cancelled 'cancelled)
                                      (success 'success)
                                      (t 'failed))))
                   (insert (upesp+:queue-row-cell
                            (format "\nCommand %s (exit code %s): %S\n"
                                    (cond (cancelled "cancelled")
                                          (success "succeeded")
                                          (t "failed"))
                                    exit-code executed-cmd)
                            (upesp+:status-face status)))
                   (setq upesp+:command-occupied nil
                         upesp+:command-executing nil
                         upesp+:command-executing-id nil
                         upesp+:command-cancelled nil)
                   (upesp+:queue-set-status executed-id status)
                   (run-hook-with-args 'upesp+:command-executed-hook
                                       executed-cmd))
                 (upesp+:run-next)))
              (t
               (let* ((normalized (upesp+:normalize-cursor-escapes output))
                      (len (length normalized))
                      (start 0))
                 ;; Chunk processing loop using regular expressions
                 (while (string-match "[\r\n]" normalized start)
                   (let* ((match (match-beginning 0))
                          (char (aref normalized match))
                          (chunk (ansi-color-apply
                                  (substring normalized start match)))
                          (chunk-len (length chunk)))
                     ;; Step 1: handle the text before the control character
                     (when (> chunk-len 0)
                       (let ((overwrite-len (- (line-end-position) (point))))
                         (when (> overwrite-len 0)
                           (delete-char overwrite-len))
                         (insert chunk)))
                     ;; Step 2: Handle the specific control character
                     (if (= char ?\r)
                         (forward-line 0)
                       (goto-char (line-end-position))
                       (insert "\n"))
                     (setq start (1+ match))))
                 ;; Step 3: Flush any remaining trailing chunk data
                 (when (< start len)
                   (let* ((chunk (ansi-color-apply
                                  (substring normalized start)))
                          (overwrite-len (- (line-end-position) (point))))
                     (when (> overwrite-len 0)
                       (delete-char overwrite-len))
                     (insert chunk))))))))))

(defun upesp+:process-sentinel (proc _event)
  (unless (process-live-p proc)
    (setq upesp+:shell-process nil
          upesp+:command-ready nil
          upesp+:command-occupied nil)))

(defun upesp+:send-command (id cmd)
  (let ((proc (upesp+:ensure-shell)))
    (if upesp+:command-ready
        (progn
          (setq upesp+:command-ready nil
                upesp+:command-executing cmd
                upesp+:command-executing-id id)
          (with-current-buffer (process-buffer proc)
            (let ((inhibit-read-only t))
              (goto-char (point-max))
              (unless (bobp)
                (insert "\n" (make-string 60 ?-) "\n"))
              (rename-buffer (upesp+:installer-buffer-name cmd) t)
              (let ((marker (point-marker)))
                (insert (upesp+:queue-row-cell
                         (format "Executing command : %S\n" cmd)
                         (upesp+:status-face 'installing)))
                (upesp+:queue-set-marker id marker))))
          (upesp+:queue-set-status id 'installing)
          (process-send-string proc (format "%s\n" cmd)))
      (run-with-timer 1 nil #'upesp+:send-command id cmd))))

(defun upesp+:finalize ()
  (setq upesp+:shell-process-terminate-timer
        (run-with-timer upesp+:shell-process-expiry nil #'upesp+:finalize-now)))

(defun upesp+:finalize-now ()
  (setq upesp+:shell-process-terminate-timer nil)
  (when upesp+:shell-process
    (kill-buffer (process-buffer upesp+:shell-process)))
  (when-let ((buf (get-buffer upesp+:queue-buffer)))
    (kill-buffer buf))
  (setq upesp+:queue-entries nil
        upesp+:queue-next-id 0))

(defun upesp+:run-next (&optional from-timer)
  (cond
   ((null from-timer)
    (run-with-timer 0 nil #'upesp+:run-next t))
   (t (unless upesp+:command-occupied
        (setq upesp+:command-occupied t)
        (let* ((item (pop upesp+:command-queue))
               (id (car item))
               (cmd (cdr item))
               (pkgmgr (upesp+:get-package-manager cmd))
               (deps (and pkgmgr (upesp+:get-package-manager-deps pkgmgr))))
          (if (and cmd pkgmgr)
              (progn
                (when deps
                  ;; Mark the package manager as bootstrapped. Requeue the
                  ;; original command. It runs again after the new
                  ;; dependency commands complete.
                  (push pkgmgr upesp+:package-manager-bootstrapped)
                  (push item upesp+:command-queue)
                  (let ((dep-items (mapcar #'upesp+:queue-enqueue deps)))
                    (setq id (car (car dep-items))
                          cmd (cdr (car dep-items)))
                    (setq upesp+:command-queue (append (cdr dep-items)
                                                       upesp+:command-queue))))
                (upesp+:send-command id cmd))
            (setq upesp+:command-occupied nil)
            (upesp+:finalize)))))))

;;;###autoload
(defun upesp+:async-shell-command (command &optional _out _err)
  (when (and command
             (not (cl-find command upesp+:command-queue
                            :key #'cdr :test #'equal)))
    (setq upesp+:command-queue
          (append upesp+:command-queue (list (upesp+:queue-enqueue command)))))
  (upesp+:run-next))

;;;###autoload
(defun upesp+:use-package-ensure-system-package-consify (arg)
  "Replace async-shell-command with upesp+:async-shell-command."
  (when (eq (cadr arg) 'async-shell-command)
    (setf (cadr arg) 'upesp+:async-shell-command))
  `(,@arg))

;;;###autoload
(advice-add 'use-package-ensure-system-package-consify
            :filter-return #'upesp+:use-package-ensure-system-package-consify)

(provide 'use-package-ensure-system-package+)
