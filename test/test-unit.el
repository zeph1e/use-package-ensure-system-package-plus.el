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
                 (lambda (cmd) (push cmd sent-cmds))))
        (setq upesp+:command-queue '("npm install foo"))
        (upesp+:run-next t)
        ;; "npm install foo" must still be in the queue (after deps)
        (should (member "npm install foo" upesp+:command-queue))
        ;; The first dep, not the original cmd, must have been sent
        (should (<= 1 (length sent-cmds)))
        (should-not (equal (car sent-cmds) "npm install foo"))))))

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
