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
  `(let ((upesp+:command-queue nil)
         (upesp+:command-done nil)
         (upesp+:command-occupied nil)
         (upesp+:shell-process nil)
         (upesp+:sentinel-counter 0))
     ,@body))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:command-need-execute

(ert-deftest upesp+:command-need-execute/returns-pair-for-new-string ()
  (upesp+:with-clean-state
    (should (equal '("apt" . "foo")
                   (upesp+:command-need-execute "apt install foo")))))

(ert-deftest upesp+:command-need-execute/strips-sudo ()
  (upesp+:with-clean-state
    (should (equal '("apt" . "foo")
                   (upesp+:command-need-execute "sudo apt install foo")))))

(ert-deftest upesp+:command-need-execute/returns-nil-on-duplicate ()
  (upesp+:with-clean-state
    (upesp+:command-need-execute "apt install foo")
    (should (null (upesp+:command-need-execute "apt install foo")))))

(ert-deftest upesp+:command-need-execute/adds-to-done ()
  (upesp+:with-clean-state
    (upesp+:command-need-execute "npm install bar")
    (should (member '("npm" . "bar") upesp+:command-done))))

(ert-deftest upesp+:command-need-execute/accepts-list-form ()
  (upesp+:with-clean-state
    (should (equal '("apt" . "foo")
                   (upesp+:command-need-execute '("apt" "install" "foo"))))))

(ert-deftest upesp+:command-need-execute/list-with-sudo ()
  (upesp+:with-clean-state
    (should (equal '("apt" . "foo")
                   (upesp+:command-need-execute '("sudo" "apt" "install" "foo"))))))

(ert-deftest upesp+:command-need-execute/distinct-packages-both-run ()
  "Two different packages under the same manager both get pairs."
  (upesp+:with-clean-state
    (should (upesp+:command-need-execute "apt install foo"))
    (should (upesp+:command-need-execute "apt install bar"))))

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
      (upesp+:run-next)
      (should (equal upesp+:command-queue '("apt install foo"))))))

(ert-deftest upesp+:run-next/empty-queue-sends-exit ()
  "Empty queue must send 'exit' to close the shared shell."
  (upesp+:with-clean-state
    (let ((sent nil)
          (buf (generate-new-buffer " *upesp-test*")))
      (let* ((proc (start-process "upesp-exit-test" buf "cat"))
             (upesp+:shell-process proc))
        (cl-letf (((symbol-function 'process-send-string)
                   (lambda (_p s) (setq sent s))))
          (upesp+:run-next)
          (should (equal sent "exit\n")))
        (delete-process proc)
        (kill-buffer buf)))))

(ert-deftest upesp+:run-next/skips-done-command-and-runs-next ()
  "A command already in command-done is skipped; the next one runs."
  (upesp+:with-clean-state
    (push '("apt" . "foo") upesp+:command-done)
    (let ((sent nil))
      (cl-letf (((symbol-function 'upesp+:send-command)
                 (lambda (cmd) (setq sent cmd)))
                ((symbol-function 'upesp+:shell-live-p) #'ignore)
                ((symbol-function 'process-send-string) #'ignore))
        (setq upesp+:command-queue '("apt install foo" "apt install bar"))
        (upesp+:run-next)
        (should (equal sent "apt install bar"))))))

(ert-deftest upesp+:run-next/requeues-behind-deps ()
  "When a package manager needs bootstrapping, cmd is re-queued after its deps."
  (upesp+:with-clean-state
    (let ((sent-cmds nil))
      (cl-letf (((symbol-function 'executable-find) (lambda (_) nil))
                ((symbol-function 'upesp+:send-command)
                 (lambda (cmd) (push cmd sent-cmds))))
        (setq upesp+:command-queue '("npm install foo"))
        (upesp+:run-next)
        ;; "npm install foo" must still be in the queue (after deps)
        (should (member "npm install foo" upesp+:command-queue))
        ;; The first dep, not the original cmd, must have been sent
        (should (= 1 (length sent-cmds)))
        (should-not (equal (car sent-cmds) "npm install foo"))))))

(ert-deftest upesp+:run-next/dep-cmd-removed-from-done-before-requeue ()
  "cmd is removed from command-done when re-queued behind deps so it will run."
  (upesp+:with-clean-state
    (cl-letf (((symbol-function 'executable-find) (lambda (_) nil))
              ((symbol-function 'upesp+:send-command) #'ignore))
      (setq upesp+:command-queue '("npm install foo"))
      (upesp+:run-next)
      ;; The pair must NOT be in done, so it runs after deps
      (should-not (member '("npm" . "foo") upesp+:command-done)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:async-shell-command

(ert-deftest upesp+:async-shell-command/enqueues-command ()
  (upesp+:with-clean-state
    (cl-letf (((symbol-function 'upesp+:run-next) #'ignore))
      (upesp+:async-shell-command "apt install foo")
      (should (member "apt install foo" upesp+:command-queue)))))

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
