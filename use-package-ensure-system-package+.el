;;; use-package-ensure-system-package+.el  -*- lexical-binding: t; -*-

;; Written by Yunsik Jang <z3ph1e@gmail.com>
;; You can use/modify/redistribute this freely.

;; This modifies the behavior of system package installation from
;; `use-package-ensure-system-package'. It runs all installs through a single
;; persistent shell session so that `sudo' only prompts for a password once.

(require 'use-package)
(require 'use-package-ensure-system-package)
(require 'cl-lib)

(defvar upesp+:command-queue nil
  "Queue of install commands to run sequentially.")

(defvar upesp+:command-done nil
  "Alist of (package-manager . package) pairs already executed.")

(defvar upesp+:command-occupied nil
  "Non-nil while waiting for the current command to finish.")

(defconst upesp+:package-manager-deps
  `(("apt" . nil)
    ("npm" . ("sudo apt install -y npm" "npm config set prefix ~/.local"))
    ("pip" . ("sudo apt install -y pip3")))
  "Bootstrap commands needed before a package manager can be used.")

;;; Shared shell process

(defvar upesp+:shell-process nil
  "The single persistent shell process used for all installs.")

(defconst upesp+:shell-buffer "*upesp+ installer*")

(defconst upesp+:sentinel-re "UPESP\\+DONE:[0-9]+"
  "Pattern written to shell stdout after each command to signal completion.")

(defvar upesp+:sentinel-counter 0)

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
  (unless (and (stringp package-manager) (executable-find package-manager))
    (cdr (assoc package-manager upesp+:package-manager-deps))))

(defun upesp+:shell-live-p ()
  (and upesp+:shell-process (process-live-p upesp+:shell-process)))

(defun upesp+:ensure-shell ()
  "Return the shared shell process, starting a fresh one if needed."
  (unless (upesp+:shell-live-p)
    (let ((buf (get-buffer-create upesp+:shell-buffer)))
      (with-current-buffer buf (erase-buffer))
      (setq upesp+:command-occupied nil
            upesp+:shell-process
            (make-process
             :name "upesp+-shell"
             :buffer buf
             :command '("/bin/bash" "--norc" "--noprofile")
             :filter #'upesp+:process-filter
             :sentinel #'upesp+:process-sentinel
             :noquery t
             :connection-type 'pipe))))
  upesp+:shell-process)

(defun upesp+:process-filter (proc output)
  (when-let ((buf (process-buffer proc)))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert output)))
  (when (string-match upesp+:sentinel-re output)
    (setq upesp+:command-occupied nil)
    (run-with-timer 0 nil #'upesp+:run-next)))

(defun upesp+:process-sentinel (proc _event)
  (unless (process-live-p proc)
    (setq upesp+:shell-process nil
          upesp+:command-occupied nil)
    (when upesp+:command-queue
      (run-with-timer 0 nil #'upesp+:run-next))))

(defun upesp+:send-command (cmd)
  (let ((proc (upesp+:ensure-shell))
        (marker (format "echo 'UPESP+DONE:%d'" (cl-incf upesp+:sentinel-counter))))
    (display-buffer (process-buffer proc) '(display-buffer-pop-up-window))
    (setq upesp+:command-occupied t)
    (process-send-string proc (format "%s\n%s\n" cmd marker))))

(defun upesp+:run-next ()
  (unless upesp+:command-occupied
    (if (null upesp+:command-queue)
        (when (upesp+:shell-live-p)
          (process-send-string upesp+:shell-process "exit\n"))
      (let* ((cmd (pop upesp+:command-queue))
             (pkg (upesp+:command-need-execute cmd))
             (deps (and pkg (upesp+:get-package-manager-deps (car pkg)))))
        (cond
         ((null pkg) (upesp+:run-next))
         (deps
          ;; Re-queue cmd after its package manager deps.
          ;; Remove from done so it actually runs once deps finish.
          (setq upesp+:command-done (cl-remove pkg upesp+:command-done :test #'equal))
          (setq upesp+:command-queue (append deps (list cmd) upesp+:command-queue))
          (upesp+:run-next))
         (t (upesp+:send-command cmd)))))))

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