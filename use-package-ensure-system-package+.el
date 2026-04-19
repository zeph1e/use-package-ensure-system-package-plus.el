;;; use-package-ensure-system-package+.el  -*- lexical-binding: t; -*-

;; Written by Yunsik Jang <z3ph1e@gmail.com>
;; You can use/modify/redistribute this freely.

;; This modifies the behavior of system package installation from
;; `use-package-ensure-system-package'. It runs all installs through a single
;; persistent shell session so that `sudo' only prompts for a password once.

(require 'use-package)
(require 'use-package-ensure-system-package)
(require 'cl-lib)
(require 'comint)
(require 'ansi-color)

(defvar upesp+:command-queue nil
  "Queue of install commands to run sequentially.")

(defvar upesp+:command-done nil
  "Alist of (package-manager . package) pairs already executed.")

(defvar upesp+:package-manager-bootstrapped nil
  "List of package managers whose bootstrap commands have been enqueued.")

(defvar upesp+:command-occupied nil
  "Non-nil while waiting for the current command to finish.")

(defvar upesp+:command-ready nil
  "Non-nil when shell is showing prompt.")

(defvar upesp+:command-executing nil
  "Non-nil when executing command in shell.")

(defcustom upesp+:package-manager-deps
  `(("apt" . nil)
    ("curl" . ("sudo apt install -y curl"))
    ("npm" . ("curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash"
              "source ~/.nvm/nvm.sh"
              "nvm install --lts"))
    ("pip" . ("sudo apt install -y build-essential"
              "sudo apt install -y zlib1g-dev"
              "sudo apt install -y libncurses5-dev"
              "sudo apt install -y libgdbm-dev"
              "sudo apt install -y libnss3-dev"
              "sudo apt install -y libssl-dev"
              "sudo apt install -y libreadline-dev"
              "sudo apt install -y libffi-dev"
              "sudo apt install -y wget"
              "curl -fsSL https://pyenv.run | bash"
              "echo 'export PYENV_ROOT=\"$HOME/.pyenv\"' >> ~/.bashrc"
              "echo '[[ -d $PYENV_ROOT/bin ]] && export PATH=\"$PYENV_ROOT/bin:$PATH\"' >> ~/.bashrc"
              "echo 'eval \"$(pyenv init - bash)\"' >> ~/.bashrc"
              "export PATH=\"$HOME/.pyenv/bin:$PATH\"")))
  "Bootstrap commands needed before a package manager can be used."
  :group 'upesp+
  :type 'alist)

;;; Shared shell process

(defvar upesp+:shell-process nil
  "The single persistent shell process used for all installs.")

(defvar upesp+:shell-process-terminate-timer nil
  "Timer handle for shell-process termination.")

(defconst upesp+:shell-buffer "*upesp+ installer*")

(defconst upesp+:shell-prompt "upesp_plus_prompt$ ")

(defun upesp+:command-need-execute (command)
  (cond
   ((stringp command)
    (upesp+:command-need-execute (split-string-shell-command command)))
   ((listp command)
    (if (and (stringp (car command)) (string= (car command) "sudo"))
        (upesp+:command-need-execute (cdr command))
      (let* ((pair (cons (car command) (car (last command))))
             (found (car (member pair upesp+:command-done))))
        (unless found
          (push pair upesp+:command-done)
          pair))))
   (t nil)))

(defun upesp+:get-package-manager-deps (package-manager)
  (unless (or (member package-manager upesp+:package-manager-bootstrapped)
              (and (stringp package-manager) (executable-find package-manager)))
    (cdr (assoc package-manager upesp+:package-manager-deps))))

(defun upesp+:shell-live-p ()
  (and upesp+:shell-process (process-live-p upesp+:shell-process)))

(defun upesp+:ensure-shell ()
  "Return the shared shell process, starting a fresh one if needed."
  (if (upesp+:shell-live-p)
      (progn
        (when upesp+:shell-process-terminate-timer
          (cancel-timer upesp+:shell-process-terminate-timer)
          (setq upesp+:shell-process-terminate-timer nil))
        upesp+:shell-process)
    (let ((buf (get-buffer-create upesp+:shell-buffer)))
      (with-current-buffer buf (erase-buffer))

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
  (let ((case-fold-search t))
    (string-match upesp+:shell-prompt
                  (string-replace "\r" "" string))))

(defun upesp+:process-filter (proc output)
  (when-let ((buf (process-buffer proc)))
    (with-current-buffer buf
      (goto-char (point-max))
      ;; (message "output: %S" output)
      (cond ((comint-watch-for-password-prompt output)
             (insert output)
             (display-buffer (process-buffer proc)
                             '(display-buffer-pop-up-window)))
            ((upesp+:watch-for-shell-prompt output)
             (setq upesp+:command-ready t)
             (when upesp+:command-executing
               (setq upesp+:command-occupied nil
                     upesp+:command-executing nil)
               (upesp+:run-next)))
            (t (ansi-color-apply (insert output)))))))

(defun upesp+:process-sentinel (proc _event)
  (unless (process-live-p proc)
    ;; (message "reset flag")
    (setq upesp+:shell-process nil
          upesp+:command-ready nil
          upesp+:command-occupied nil)))

(defun upesp+:send-command (cmd)
  (let ((proc (upesp+:ensure-shell)))
    ;; (display-buffer (process-buffer proc) '(display-buffer-pop-up-window))
    (if upesp+:command-ready
        (progn
          ;; (message "sending cmd: %S" cmd)
          (setq upesp+:command-ready nil
                upesp+:command-executing t)
          (with-current-buffer (process-buffer proc)
            (insert (format "Executing command : %S\n" cmd)))
          ;; (message "executing command: %S" cmd)
          (process-send-string proc (format "%s\n" cmd)))
      (run-with-timer 1 nil #'upesp+:send-command cmd))))

(defun upesp+:finalize ()
  (setq upesp+:shell-process-terminate-timer
        (run-with-timer 10 nil #'upesp+:finalize-now)))

(defun upesp+:finalize-now ()
  ;; (message "killing buffer")
  (setq upesp+:shell-process-terminate-timer nil)
  (when upesp+:shell-process
    (kill-buffer (process-buffer upesp+:shell-process))))

(defun upesp+:run-next (&optional from-timer)
  (cond
   ((null from-timer)
    (run-with-timer 0 nil #'upesp+:run-next t))
   (t (unless upesp+:command-occupied
        (setq upesp+:command-occupied t)
        (let* ((cmd (pop upesp+:command-queue))
               (pkg (upesp+:command-need-execute cmd))
               (deps (and pkg (upesp+:get-package-manager-deps (car pkg)))))
          ;; (message "cmd: %S, pkg: %S, deps: %S" cmd pkg deps)
          (if (and cmd pkg)
              (progn
                (when deps
                  ;; Bootstrap the package manager first.
                  ;; Mark as bootstrapped and undo the premature command-done
                  ;; entry so the original command runs after deps complete.
                  (push (car pkg) upesp+:package-manager-bootstrapped)
                  (setq upesp+:command-done
                        (cl-remove pkg upesp+:command-done :test #'equal))
                  (push cmd upesp+:command-queue)
                  (setq cmd (car deps))
                  (setq upesp+:command-queue (append (cdr deps)
                                                     upesp+:command-queue)))
                (upesp+:send-command cmd))
            (setq upesp+:command-occupied nil)
            (upesp+:finalize)))))))

;;;###autoload
(defun upesp+:async-shell-command (command &optional _out _err)
  (when command
    (add-to-list 'upesp+:command-queue command t))
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
