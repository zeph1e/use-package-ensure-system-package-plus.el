;;; test-unit.el --- Unit tests for use-package-ensure-system-package+  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

;;; Stub dependencies so the plugin loads without use-package installed

(unless (featurep 'use-package)
  (provide 'use-package))

(unless (featurep 'use-package-ensure-system-package)
  (defun use-package-ensure-system-package-consify (arg) arg)
  (provide 'use-package-ensure-system-package))

(load (expand-file-name
       "../use-package-ensure-system-package+.el"
       (file-name-directory (or load-file-name buffer-file-name))))

;;; Helper: reset all plugin state before each test

(defmacro upesp+:with-clean-state (&rest body)
  "Run BODY with all plugin state vars reset to nil."
  (declare (indent 0))
  `(let ((upesp+:package-manager-bootstrapped nil)
         (upesp+:command-queue nil)
         (upesp+:command-occupied nil)
         (upesp+:command-ready nil)
         (upesp+:command-executing nil)
         (upesp+:command-executing-id nil)
         (upesp+:command-cancelled nil)
         (upesp+:queue-entries nil)
         (upesp+:queue-next-id 0)
         (upesp+:shell-process nil))
     ,@body))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:get-package-manager

(ert-deftest upesp+:get-package-manager/returns-package-manager-string ()
  (upesp+:with-clean-state
    (should (equal "apt" (upesp+:get-package-manager "apt install foo")))))

(ert-deftest upesp+:get-package-manager/strips-sudo ()
  (upesp+:with-clean-state
    (should (equal "apt" (upesp+:get-package-manager "sudo apt install foo")))))

(ert-deftest upesp+:get-package-manager/accepts-list-form ()
  (upesp+:with-clean-state
    (should (equal "apt"
                   (upesp+:get-package-manager '("apt" "install" "foo"))))))

(ert-deftest upesp+:get-package-manager/list-with-sudo ()
  (upesp+:with-clean-state
    (should (equal "apt"
                   (upesp+:get-package-manager '("sudo" "apt" "install" "foo"))))))

(ert-deftest upesp+:get-package-manager/allow-redundancy ()
  "Always return package manager name regardless of the redundancy."
  (upesp+:with-clean-state
    (should (upesp+:get-package-manager "apt install foo"))
    (should (upesp+:get-package-manager "apt install foo"))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:get-package-manager-deps

(ert-deftest upesp+:get-pm-deps/returns-nil-when-present ()
  (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/apt")))
    (should (null (upesp+:get-package-manager-deps "apt")))))

(ert-deftest upesp+:get-pm-deps/returns-deps-when-npm-missing ()
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (let ((deps (upesp+:get-package-manager-deps "npm")))
      (should (listp deps))
      (should (> (length deps) 0)))))

(ert-deftest upesp+:get-pm-deps/returns-nil-for-unknown-manager ()
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (should (null (upesp+:get-package-manager-deps "unknown-pm")))))

(ert-deftest upesp+:get-pm-deps/apt-has-no-bootstrap ()
  "apt is assumed always present; its deps entry is nil."
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (should (null (upesp+:get-package-manager-deps "apt")))))

(ert-deftest upesp+:get-pm-deps/returns-deps-when-curl-missing ()
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (let ((deps (upesp+:get-package-manager-deps "curl")))
      (should (listp deps))
      (should (> (length deps) 0)))))

(ert-deftest upesp+:get-pm-deps/curl-bootstrap-uses-apt ()
  "curl is bootstrapped via apt."
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (should (string-match "apt" (car (upesp+:get-package-manager-deps "curl"))))))

(ert-deftest upesp+:get-pm-deps/npm-bootstrap-uses-nvm ()
  "npm is bootstrapped via nvm, not a direct apt install."
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (should (string-match "nvm" (car (upesp+:get-package-manager-deps "npm"))))))

(ert-deftest upesp+:get-pm-deps/pip-bootstrap-uses-python3-pip ()
  "pip is bootstrapped by installing python3-pip."
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (should (string-match "python3-pip"
                          (car (upesp+:get-package-manager-deps "pip"))))))

(ert-deftest upesp+:get-pm-deps/returns-nil-when-already-bootstrapped ()
  "Once a manager is in bootstrapped list, no deps returned even if missing."
  (upesp+:with-clean-state
    (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
      (let ((upesp+:package-manager-bootstrapped '("npm")))
        (should (null (upesp+:get-package-manager-deps "npm")))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:shell-live-p

(ert-deftest upesp+:shell-live-p/nil-process ()
  (upesp+:with-clean-state
    (should (null (upesp+:shell-live-p)))))

(ert-deftest upesp+:shell-live-p/dead-process ()
  (upesp+:with-clean-state
    (let* ((proc (start-process "upesp-dead-test" nil "true"))
           (upesp+:shell-process proc))
      (sleep-for 0.3)
      (should (null (upesp+:shell-live-p))))))

(ert-deftest upesp+:shell-live-p/live-process ()
  (upesp+:with-clean-state
    (let* ((proc (start-process "upesp-live-test" nil "sleep" "60"))
           (upesp+:shell-process proc))
      (unwind-protect
          (should (upesp+:shell-live-p))
        (delete-process proc)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:run-next

(ert-deftest upesp+:run-next/noop-when-occupied ()
  "When occupied, run-next must not pop the queue."
  (upesp+:with-clean-state
    (setq upesp+:command-occupied t
          upesp+:command-queue '("apt install foo"))
    (cl-letf (((symbol-function 'upesp+:send-command) #'ignore))
      (upesp+:run-next t)
      (should (equal upesp+:command-queue '("apt install foo"))))))

(ert-deftest upesp+:run-next/empty-queue-finalizes ()
  "Empty queue must call upesp+:finalize to close the shell."
  (upesp+:with-clean-state
    (let ((finalized nil))
      (cl-letf (((symbol-function 'upesp+:finalize)
                 (lambda () (setq finalized t))))
        (upesp+:run-next t)
        (should finalized)))))

(ert-deftest upesp+:run-next/requeues-behind-deps ()
  "When a package manager needs bootstrapping, cmd is re-queued after its deps."
  (upesp+:with-clean-state
    (let ((sent-cmds nil))
      (cl-letf (((symbol-function 'executable-find) (lambda (_) nil))
                ((symbol-function 'upesp+:send-command)
                 (lambda (_id cmd) (push cmd sent-cmds))))
        (setq upesp+:command-queue (list (cons 1 "npm install foo")))
        (upesp+:run-next t)
        ;; "npm install foo" must still be in the queue (after deps)
        (should (cl-find "npm install foo" upesp+:command-queue
                          :key #'cdr :test #'equal))
        ;; The first dep, not the original cmd, must have been sent
        (should (<= 1 (length sent-cmds)))
        (should-not (equal (car sent-cmds) "npm install foo"))))))

(ert-deftest upesp+:run-next/sets-bootstrapped-flag-when-requeuing ()
  "Manager is pushed to bootstrapped list when its deps are prepended."
  (upesp+:with-clean-state
    (cl-letf (((symbol-function 'executable-find) (lambda (_) nil))
              ((symbol-function 'upesp+:send-command) #'ignore))
      (setq upesp+:command-queue (list (cons 1 "npm install foo")))
      (upesp+:run-next t)
      (should (member "npm" upesp+:package-manager-bootstrapped)))))

(ert-deftest upesp+:run-next/bootstrapped-manager-sends-directly ()
  "When manager is already bootstrapped, original cmd is sent without requeuing."
  (upesp+:with-clean-state
    (let ((sent nil))
      (cl-letf (((symbol-function 'executable-find) (lambda (_) nil))
                ((symbol-function 'upesp+:send-command)
                 (lambda (_id cmd) (setq sent cmd))))
        (setq upesp+:package-manager-bootstrapped '("npm")
              upesp+:command-queue (list (cons 1 "npm install foo")))
        (upesp+:run-next t)
        (should (equal sent "npm install foo"))
        (should (null upesp+:command-queue))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:send-command

(defmacro upesp+:with-fake-shell (buf &rest body)
  "Run BODY with upesp+:ensure-shell/process-send-string/rename-buffer stubbed
so upesp+:send-command writes into BUF without touching a real process."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'upesp+:ensure-shell) (lambda () 'fake-proc))
             ((symbol-function 'process-buffer) (lambda (_) ,buf))
             ((symbol-function 'process-send-string) #'ignore)
             ((symbol-function 'rename-buffer) #'ignore))
     ,@body))

(ert-deftest upesp+:send-command/does-not-erase-previous-output ()
  "A second command must not erase the first command's log, and the two
sections must be separated by a dash line."
  (upesp+:with-clean-state
    (with-temp-buffer
      (let ((buf (current-buffer))
            (upesp+:command-ready t))
        (upesp+:with-fake-shell buf
          (upesp+:send-command 1 "echo one")
          (setq upesp+:command-ready t)
          (upesp+:send-command 2 "echo two"))
        (should (string-match-p "echo one" (buffer-string)))
        (should (string-match-p "echo two" (buffer-string)))
        (should (string-match-p (regexp-quote (make-string 60 ?-)) (buffer-string)))))))

(ert-deftest upesp+:send-command/records-marker-in-queue-entry ()
  "send-command must record a marker for its queue entry, pointing at its
own log's start rather than some other entry's."
  (upesp+:with-clean-state
    (with-temp-buffer
      (let* ((buf (current-buffer))
             (entry (make-upesp+:queue-entry :id 1 :cmd "echo one" :label "echo one"
                                              :pkgmgr "echo" :status 'waiting))
             (upesp+:queue-entries (list entry))
             (upesp+:command-ready t))
        (upesp+:with-fake-shell buf
          (upesp+:send-command 1 "echo one"))
        (let ((marker (upesp+:queue-entry-marker entry)))
          (should (markerp marker))
          (should (eq buf (marker-buffer marker)))
          (should (string-match-p "\\`Executing command"
                                   (buffer-substring-no-properties marker (point-max)))))))))

(ert-deftest upesp+:send-command/executing-line-is-bold ()
  (upesp+:with-clean-state
    (with-temp-buffer
      (let ((buf (current-buffer))
            (upesp+:command-ready t))
        (upesp+:with-fake-shell buf
          (upesp+:send-command 1 "echo one"))
        (should (eq 'bold (get-text-property (point-min) 'face)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:process-filter / upesp+:command-executed-hook

(ert-deftest upesp+:process-filter/hook-fires-with-command-string ()
  "command-executed-hook receives the command string that was executing."
  (upesp+:with-clean-state
    (let* ((received nil)
           (upesp+:command-executing "apt install foo")
           (hook-fn (lambda (cmd) (setq received cmd))))
      (add-hook 'upesp+:command-executed-hook hook-fn)
      (unwind-protect
          (with-temp-buffer
            (cl-letf (((symbol-function 'process-buffer) (lambda (_) (current-buffer)))
                      ((symbol-function 'comint-watch-for-password-prompt) (lambda (_) nil))
                      ((symbol-function 'upesp+:watch-for-shell-prompt) (lambda (_) "0"))
                      ((symbol-function 'upesp+:run-next) #'ignore))
              (upesp+:process-filter nil "anything")
              (should (equal received "apt install foo"))))
        (remove-hook 'upesp+:command-executed-hook hook-fn)))))

(ert-deftest upesp+:process-filter/state-cleared-before-hook ()
  "command-occupied and command-executing are nil when the hook fires."
  (upesp+:with-clean-state
    (let* ((occupied-in-hook :unset)
           (executing-in-hook :unset)
           (upesp+:command-executing "apt install foo")
           (upesp+:command-occupied t)
           (hook-fn (lambda (_cmd)
                      (setq occupied-in-hook upesp+:command-occupied
                            executing-in-hook upesp+:command-executing))))
      (add-hook 'upesp+:command-executed-hook hook-fn)
      (unwind-protect
          (with-temp-buffer
            (cl-letf (((symbol-function 'process-buffer) (lambda (_) (current-buffer)))
                      ((symbol-function 'comint-watch-for-password-prompt) (lambda (_) nil))
                      ((symbol-function 'upesp+:watch-for-shell-prompt) (lambda (_) "0"))
                      ((symbol-function 'upesp+:run-next) #'ignore))
              (upesp+:process-filter nil "anything")
              (should (null occupied-in-hook))
              (should (null executing-in-hook))))
        (remove-hook 'upesp+:command-executed-hook hook-fn)))))

(ert-deftest upesp+:process-filter/password-prompt-defers-to-timer ()
  "A password-prompt line must not read the password synchronously inside
the filter (quitting there cannot reach `read-passwd', see
`upesp+:ask-password'); it must schedule `upesp+:ask-password' via a
zero-delay timer instead, and touch no cancellation state itself."
  (upesp+:with-clean-state
    (with-temp-buffer
      (let (scheduled)
        (cl-letf (((symbol-function 'process-buffer) (lambda (_) (current-buffer)))
                  ((symbol-function 'get-buffer-window) (lambda (&rest _) nil))
                  ((symbol-function 'display-buffer) #'ignore)
                  ((symbol-function 'run-with-timer)
                   (lambda (secs repeat fn &rest args)
                     (setq scheduled (list secs repeat fn args)))))
          (upesp+:process-filter 'fake-proc "[sudo] password for user: ")
          (should (equal (nth 0 scheduled) 0))
          (should (null (nth 1 scheduled)))
          (should (eq (nth 2 scheduled) 'upesp+:ask-password))
          (should (equal (nth 3 scheduled)
                          (list 'fake-proc (current-buffer)
                                "[sudo] password for user: ")))
          (should (null upesp+:command-cancelled)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:extra-password-prompt-regexp

(ert-deftest upesp+:extra-password-prompt-regexp/matches-bracketed-sudo-rs-prompt ()
  "Matches the bracketed prompt some newer distributions use, for example
sudo-rs on Ubuntu 26.04, which `comint-password-prompt-regexp' misses."
  (let ((case-fold-search t))
    (should (string-match-p upesp+:extra-password-prompt-regexp
                            "[sudo: authenticate] Password: "))
    (should (string-match-p upesp+:extra-password-prompt-regexp
                            "[sudo: retry] Password: "))))

(ert-deftest upesp+:extra-password-prompt-regexp/does-not-match-classic-prompt ()
  "The classic prompt is already `comint-password-prompt-regexp''s job."
  (let ((case-fold-search t))
    (should-not (string-match-p upesp+:extra-password-prompt-regexp
                                "[sudo] password for user: "))
    (should-not (string-match-p upesp+:extra-password-prompt-regexp
                                "Password: "))))

(ert-deftest upesp+:extra-password-prompt-regexp/does-not-match-mid-string-or-trailing-text ()
  "Only a chunk that starts with the bracket and ends at the colon counts."
  (let ((case-fold-search t))
    (should-not (string-match-p upesp+:extra-password-prompt-regexp
                                "some other [sudo: authenticate] text"))
    (should-not (string-match-p upesp+:extra-password-prompt-regexp
                                "[sudo: authenticate] Password: extra"))))

(ert-deftest upesp+:process-filter/recognizes-bracketed-sudo-rs-prompt ()
  "The filter's password-prompt branch must also fire for the bracketed
prompt, not only for `comint-password-prompt-regexp''s classic form."
  (upesp+:with-clean-state
    (with-temp-buffer
      (let (scheduled)
        (cl-letf (((symbol-function 'process-buffer) (lambda (_) (current-buffer)))
                  ((symbol-function 'get-buffer-window) (lambda (&rest _) nil))
                  ((symbol-function 'display-buffer) #'ignore)
                  ((symbol-function 'run-with-timer)
                   (lambda (secs repeat fn &rest args)
                     (setq scheduled (list secs repeat fn args)))))
          (upesp+:process-filter 'fake-proc "[sudo: authenticate] Password: ")
          (should (eq (nth 2 scheduled) 'upesp+:ask-password)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:ask-password

(ert-deftest upesp+:ask-password/sends-entered-password-to-process ()
  (with-temp-buffer
    (let ((buf (current-buffer))
          sent)
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-send-string)
                 (lambda (_proc str) (setq sent str)))
                ((symbol-function 'read-passwd) (lambda (_prompt) "hunter2")))
        (upesp+:ask-password 'fake-proc buf "Password: ")
        (should (equal sent "hunter2\n"))))))

(ert-deftest upesp+:ask-password/quit-interrupts-process-and-marks-cancelled ()
  "A quit signalled from `read-passwd' (standing in for a real C-g, which
this function's whole point is to let behave normally — see the call site
in `upesp+:process-filter') must not propagate; it interrupts the process
and records the cancellation on BUF."
  (upesp+:with-clean-state
    (with-temp-buffer
      (let ((buf (current-buffer))
            interrupt-sent)
        (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                  ((symbol-function 'process-send-string)
                   (lambda (_proc str) (setq interrupt-sent str)))
                  ((symbol-function 'read-passwd) (lambda (_prompt) (signal 'quit nil))))
          ;; Must return normally — the quit is caught inside.
          (upesp+:ask-password 'fake-proc buf "Password: ")
          (should (equal interrupt-sent "\C-c"))
          (should upesp+:command-cancelled)
          (should (string-match-p "cancelled" (buffer-string))))))))

(ert-deftest upesp+:ask-password/noop-when-buffer-already-killed ()
  (let (buf)
    (with-temp-buffer (setq buf (current-buffer)))
    (should (null (upesp+:ask-password 'fake-proc buf "Password: ")))))

(ert-deftest upesp+:process-filter/cancelled-flag-yields-cancelled-status ()
  "Once upesp+:command-cancelled is set, the exit-code branch records
`'cancelled' instead of `'success'/`'failed', and resets the flag."
  (upesp+:with-clean-state
    (with-temp-buffer
      (let* ((entry (make-upesp+:queue-entry :id 1 :cmd "sudo apt install foo"
                                              :label "foo" :pkgmgr "apt" :status 'installing))
             (upesp+:queue-entries (list entry))
             (upesp+:command-executing "sudo apt install foo")
             (upesp+:command-executing-id 1)
             (upesp+:command-cancelled t))
        (cl-letf (((symbol-function 'process-buffer) (lambda (_) (current-buffer)))
                  ((symbol-function 'upesp+:watch-for-shell-prompt) (lambda (_) "130"))
                  ((symbol-function 'upesp+:run-next) #'ignore))
          (upesp+:process-filter 'fake-proc "upesp_plus_prompt:130$ ")
          (should (eq 'cancelled (upesp+:queue-entry-status entry)))
          (should (null upesp+:command-cancelled)))))))

(ert-deftest upesp+:process-filter/result-line-success-face ()
  "The exit-code branch's own result line is colored like the queue row."
  (upesp+:with-clean-state
    (with-temp-buffer
      (let ((upesp+:command-executing "echo x")
            (upesp+:command-executing-id 1))
        (cl-letf (((symbol-function 'process-buffer) (lambda (_) (current-buffer)))
                  ((symbol-function 'upesp+:watch-for-shell-prompt) (lambda (_) "0"))
                  ((symbol-function 'upesp+:queue-set-status) #'ignore)
                  ((symbol-function 'upesp+:run-next) #'ignore))
          (upesp+:process-filter 'fake-proc "upesp_plus_prompt:0$ ")
          (should (eq 'success (get-text-property (point-min) 'face))))))))

(ert-deftest upesp+:process-filter/result-line-error-face ()
  (upesp+:with-clean-state
    (with-temp-buffer
      (let ((upesp+:command-executing "echo x")
            (upesp+:command-executing-id 1))
        (cl-letf (((symbol-function 'process-buffer) (lambda (_) (current-buffer)))
                  ((symbol-function 'upesp+:watch-for-shell-prompt) (lambda (_) "1"))
                  ((symbol-function 'upesp+:queue-set-status) #'ignore)
                  ((symbol-function 'upesp+:run-next) #'ignore))
          (upesp+:process-filter 'fake-proc "upesp_plus_prompt:1$ ")
          (should (eq 'error (get-text-property (point-min) 'face))))))))

(ert-deftest upesp+:process-filter/result-line-no-face-when-cancelled ()
  (upesp+:with-clean-state
    (with-temp-buffer
      (let ((upesp+:command-executing "echo x")
            (upesp+:command-executing-id 1)
            (upesp+:command-cancelled t))
        (cl-letf (((symbol-function 'process-buffer) (lambda (_) (current-buffer)))
                  ((symbol-function 'upesp+:watch-for-shell-prompt) (lambda (_) "0"))
                  ((symbol-function 'upesp+:queue-set-status) #'ignore)
                  ((symbol-function 'upesp+:run-next) #'ignore))
          (upesp+:process-filter 'fake-proc "upesp_plus_prompt:0$ ")
          (should (null (get-text-property (point-min) 'face))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:status-face

(ert-deftest upesp+:status-face/mapping ()
  (should (eq 'bold (upesp+:status-face 'installing)))
  (should (eq 'success (upesp+:status-face 'success)))
  (should (eq 'error (upesp+:status-face 'failed)))
  (should (null (upesp+:status-face 'cancelled)))
  (should (null (upesp+:status-face 'waiting))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:queue-entry->row

(ert-deftest upesp+:queue-entry-row/gray-when-no-marker ()
  "A queue row with no marker (command never started) is shown in `shadow' face."
  (let* ((entry (make-upesp+:queue-entry :id 1 :cmd "echo x" :label "echo x"
                                          :pkgmgr "echo" :status 'waiting :marker nil))
         (cells (cadr (upesp+:queue-entry->row entry))))
    (should (eq 'shadow (get-text-property 0 'face (aref cells 0))))
    (should (eq 'shadow (get-text-property 0 'face (aref cells 2))))))

(ert-deftest upesp+:queue-entry-row/no-face-when-cancelled ()
  "Once a marker is recorded, the row is no longer gray; `'cancelled' also
gets no distinct face of its own (unlike installing/success/failed)."
  (with-temp-buffer
    (let* ((entry (make-upesp+:queue-entry :id 1 :cmd "echo x" :label "echo x"
                                            :pkgmgr "echo" :status 'cancelled
                                            :marker (point-marker)))
           (cells (cadr (upesp+:queue-entry->row entry))))
      (should (null (get-text-property 0 'face (aref cells 0)))))))

(ert-deftest upesp+:queue-entry-row/bold-when-installing ()
  (with-temp-buffer
    (let* ((entry (make-upesp+:queue-entry :id 1 :cmd "echo x" :label "echo x"
                                            :pkgmgr "echo" :status 'installing
                                            :marker (point-marker)))
           (cells (cadr (upesp+:queue-entry->row entry))))
      (should (eq 'bold (get-text-property 0 'face (aref cells 0))))
      (should (eq 'bold (get-text-property 0 'face (aref cells 2)))))))

(ert-deftest upesp+:queue-entry-row/success-face-when-succeeded ()
  (with-temp-buffer
    (let* ((entry (make-upesp+:queue-entry :id 1 :cmd "echo x" :label "echo x"
                                            :pkgmgr "echo" :status 'success
                                            :marker (point-marker)))
           (cells (cadr (upesp+:queue-entry->row entry))))
      (should (eq 'success (get-text-property 0 'face (aref cells 0))))
      (should (eq 'success (get-text-property 0 'face (aref cells 2)))))))

(ert-deftest upesp+:queue-entry-row/error-face-when-failed ()
  (with-temp-buffer
    (let* ((entry (make-upesp+:queue-entry :id 1 :cmd "echo x" :label "echo x"
                                            :pkgmgr "echo" :status 'failed
                                            :marker (point-marker)))
           (cells (cadr (upesp+:queue-entry->row entry))))
      (should (eq 'error (get-text-property 0 'face (aref cells 0))))
      (should (eq 'error (get-text-property 0 'face (aref cells 2)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:queue-set-marker

(ert-deftest upesp+:queue-set-marker/sets-marker-on-matching-entry ()
  (upesp+:with-clean-state
    (with-temp-buffer
      (let ((entry (make-upesp+:queue-entry :id 3 :cmd "echo x" :label "echo x"
                                             :pkgmgr "echo" :status 'installing))
            (marker (point-marker)))
        (let ((upesp+:queue-entries (list entry)))
          (upesp+:queue-set-marker 3 marker)
          (should (eq marker (upesp+:queue-entry-marker entry))))))))

(ert-deftest upesp+:queue-set-marker/noop-for-unknown-id ()
  (upesp+:with-clean-state
    (should (null (upesp+:queue-set-marker 999 'irrelevant)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:queue-jump-to-command

(ert-deftest upesp+:queue-jump/no-entry-selected-messages ()
  (upesp+:with-clean-state
    (let (msg)
      (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () nil))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (upesp+:queue-jump-to-command)
        (should (string-match-p "no command selected" msg))))))

(ert-deftest upesp+:queue-jump/waiting-entry-messages-without-navigating ()
  "A row with no marker (not started yet) must not pop up any buffer."
  (upesp+:with-clean-state
    (let* ((entry (make-upesp+:queue-entry :id 5 :cmd "echo x" :label "echo x"
                                            :pkgmgr "echo" :status 'waiting :marker nil))
           (upesp+:queue-entries (list entry))
           msg displayed)
      (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () 5))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args))))
                ((symbol-function 'display-buffer) (lambda (&rest _) (setq displayed t))))
        (upesp+:queue-jump-to-command)
        (should (string-match-p "not started yet" msg))
        (should (null displayed))))))

(ert-deftest upesp+:queue-jump/dead-installer-buffer-messages ()
  (upesp+:with-clean-state
    (let* ((marker (let (m) (with-temp-buffer (setq m (point-marker))) m))
           (entry (make-upesp+:queue-entry :id 7 :cmd "echo x" :label "echo x"
                                            :pkgmgr "echo" :status 'success :marker marker))
           (upesp+:queue-entries (list entry))
           msg)
      (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () 7))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (upesp+:queue-jump-to-command)
        (should (string-match-p "no longer exists" msg))))))

(ert-deftest upesp+:queue-jump/live-marker-navigates ()
  (upesp+:with-clean-state
    (with-temp-buffer
      (let* ((marker (point-marker))
             (entry (make-upesp+:queue-entry :id 9 :cmd "echo x" :label "echo x"
                                              :pkgmgr "echo" :status 'success :marker marker))
             (upesp+:queue-entries (list entry))
             (fake-win 'fake-window)
             set-point-args selected)
        (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () 9))
                  ((symbol-function 'display-buffer) (lambda (&rest _) fake-win))
                  ((symbol-function 'set-window-point)
                   (lambda (win pos) (setq set-point-args (list win pos))))
                  ((symbol-function 'select-window) (lambda (win) (setq selected win))))
          (upesp+:queue-jump-to-command)
          (should (equal set-point-args (list fake-win marker)))
          (should (eq selected fake-win)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:queue-restart-command

(ert-deftest upesp+:queue-restart/no-entry-selected-messages ()
  (upesp+:with-clean-state
    (let (msg)
      (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () nil))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (upesp+:queue-restart-command)
        (should (string-match-p "no command selected" msg))))))

(ert-deftest upesp+:queue-restart/non-cancelled-or-failed-messages-without-resubmitting ()
  (upesp+:with-clean-state
    (let* ((entry (make-upesp+:queue-entry :id 1 :cmd "echo x" :label "echo x"
                                            :pkgmgr "echo" :status 'success))
           (upesp+:queue-entries (list entry))
           msg resubmitted)
      (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () 1))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args))))
                ((symbol-function 'upesp+:async-shell-command)
                 (lambda (cmd) (setq resubmitted cmd))))
        (upesp+:queue-restart-command)
        (should (string-match-p "only a cancelled or failed" msg))
        (should (null resubmitted))))))

(ert-deftest upesp+:queue-restart/cancelled-entry-resubmits-its-command ()
  (upesp+:with-clean-state
    (let* ((entry (make-upesp+:queue-entry :id 2 :cmd "echo cancelled-cmd" :label "echo cancelled-cmd"
                                            :pkgmgr "echo" :status 'cancelled))
           (upesp+:queue-entries (list entry))
           resubmitted)
      (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () 2))
                ((symbol-function 'upesp+:async-shell-command)
                 (lambda (cmd) (setq resubmitted cmd))))
        (upesp+:queue-restart-command)
        (should (equal resubmitted "echo cancelled-cmd"))))))

(ert-deftest upesp+:queue-restart/failed-entry-resubmits-its-command ()
  (upesp+:with-clean-state
    (let* ((entry (make-upesp+:queue-entry :id 3 :cmd "echo failed-cmd" :label "echo failed-cmd"
                                            :pkgmgr "echo" :status 'failed))
           (upesp+:queue-entries (list entry))
           resubmitted)
      (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () 3))
                ((symbol-function 'upesp+:async-shell-command)
                 (lambda (cmd) (setq resubmitted cmd))))
        (upesp+:queue-restart-command)
        (should (equal resubmitted "echo failed-cmd"))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:queue-kill-command

(ert-deftest upesp+:queue-kill/no-entry-selected-messages ()
  (upesp+:with-clean-state
    (let (msg)
      (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () nil))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (upesp+:queue-kill-command)
        (should (string-match-p "no command selected" msg))))))

(ert-deftest upesp+:queue-kill/non-installing-entry-messages-without-interrupting ()
  (upesp+:with-clean-state
    (let* ((entry (make-upesp+:queue-entry :id 1 :cmd "echo x" :label "echo x"
                                            :pkgmgr "echo" :status 'waiting))
           (upesp+:queue-entries (list entry))
           msg sent)
      (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () 1))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args))))
                ((symbol-function 'process-send-string) (lambda (&rest _) (setq sent t))))
        (upesp+:queue-kill-command)
        (should (string-match-p "only the currently installing" msg))
        (should (null sent))
        (should (null upesp+:command-cancelled))))))

(ert-deftest upesp+:queue-kill/no-live-shell-messages ()
  (upesp+:with-clean-state
    (let* ((entry (make-upesp+:queue-entry :id 1 :cmd "echo x" :label "echo x"
                                            :pkgmgr "echo" :status 'installing))
           (upesp+:queue-entries (list entry))
           msg)
      (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () 1))
                ((symbol-function 'upesp+:shell-live-p) (lambda () nil))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (upesp+:queue-kill-command)
        (should (string-match-p "no running shell" msg))))))

(ert-deftest upesp+:queue-kill/installing-entry-interrupts-shell ()
  (upesp+:with-clean-state
    (let* ((entry (make-upesp+:queue-entry :id 1 :cmd "echo x" :label "echo x"
                                            :pkgmgr "echo" :status 'installing))
           (upesp+:queue-entries (list entry))
           (upesp+:shell-process 'fake-proc)
           interrupt-proc interrupt-sent)
      (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () 1))
                ((symbol-function 'upesp+:shell-live-p) (lambda () t))
                ((symbol-function 'process-send-string)
                 (lambda (proc str) (setq interrupt-proc proc interrupt-sent str))))
        (upesp+:queue-kill-command)
        (should (equal interrupt-sent "\C-c"))
        (should (eq interrupt-proc 'fake-proc))
        (should upesp+:command-cancelled)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:async-shell-command

(ert-deftest upesp+:async-shell-command/enqueues-command ()
  (upesp+:with-clean-state
    (cl-letf (((symbol-function 'upesp+:run-next) #'ignore))
      (upesp+:async-shell-command "apt install foo")
      (should (cl-find "apt install foo" upesp+:command-queue
                        :key #'cdr :test #'equal)))))

(ert-deftest upesp+:async-shell-command/calls-run-next ()
  (upesp+:with-clean-state
    (let ((called nil))
      (cl-letf (((symbol-function 'upesp+:run-next) (lambda () (setq called t))))
        (upesp+:async-shell-command "apt install foo")
        (should called)))))

(ert-deftest upesp+:async-shell-command/nil-command-still-calls-run-next ()
  "Passing nil must still call run-next (used to drain remaining queue)."
  (upesp+:with-clean-state
    (let ((called nil))
      (cl-letf (((symbol-function 'upesp+:run-next) (lambda () (setq called t))))
        (upesp+:async-shell-command nil)
        (should called)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:use-package-ensure-system-package-consify

(ert-deftest upesp+:consify/replaces-async-shell-command ()
  (let ((result (upesp+:use-package-ensure-system-package-consify
                 '(some-form async-shell-command other))))
    (should (eq 'upesp+:async-shell-command (cadr result)))))

(ert-deftest upesp+:consify/leaves-other-functions-unchanged ()
  (let ((result (upesp+:use-package-ensure-system-package-consify
                 '(some-form other-fn other))))
    (should (eq 'other-fn (cadr result)))))

(ert-deftest upesp+:consify/preserves-remaining-args ()
  (let ((result (upesp+:use-package-ensure-system-package-consify
                 '(a async-shell-command b c))))
    (should (equal '(a upesp+:async-shell-command b c) result))))

;;; test-unit.el ends here
