;;; test-functional.el --- Functional tests for use-package-ensure-system-package+  -*- lexical-binding: t; -*-

;; These tests exercise the actual shell process lifecycle end-to-end.
;; They spawn real /bin/bash processes and verify async behaviour.

(require 'ert)
(require 'cl-lib)

(unless (featurep 'use-package)
  (provide 'use-package))
(unless (featurep 'use-package-ensure-system-package)
  (defun use-package-ensure-system-package-consify (arg) arg)
  (provide 'use-package-ensure-system-package))

(load (expand-file-name
       "../use-package-ensure-system-package+.el"
       (file-name-directory (or load-file-name buffer-file-name))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Helpers

(defmacro upesp+:func-with-clean-state (&rest body)
  "Run BODY with clean plugin state, killing any leftover shell on exit."
  (declare (indent 0))
  `(let ((upesp+:command-queue nil)
         (upesp+:command-done nil)
         (upesp+:command-occupied nil)
         (upesp+:shell-process nil)
         (upesp+:sentinel-counter 0))
     (unwind-protect
         (progn ,@body)
       (when (upesp+:shell-live-p)
         (delete-process upesp+:shell-process)))))

(defun upesp+:test-wait (predicate &optional timeout-secs)
  "Poll PREDICATE every 50 ms until it returns non-nil or TIMEOUT-SECS elapses.
Returns the predicate value or nil on timeout."
  (let ((deadline (+ (float-time) (or timeout-secs 10)))
        result)
    (while (and (not (setq result (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    result))

(defun upesp+:test-shell-output ()
  "Return the accumulated output in the installer buffer."
  (when-let ((buf (get-buffer upesp+:shell-buffer)))
    (with-current-buffer buf (buffer-string))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Shell process lifecycle

(ert-deftest upesp+:func/ensure-shell-creates-process ()
  "upesp+:ensure-shell starts a live bash process."
  (upesp+:func-with-clean-state
    (upesp+:ensure-shell)
    (should (upesp+:shell-live-p))))

(ert-deftest upesp+:func/ensure-shell-reuses-existing ()
  "Calling ensure-shell twice returns the same process."
  (upesp+:func-with-clean-state
    (let ((p1 (upesp+:ensure-shell))
          (p2 (upesp+:ensure-shell)))
      (should (eq p1 p2)))))

(ert-deftest upesp+:func/ensure-shell-recreates-after-close ()
  "After the shell exits, ensure-shell spawns a fresh process."
  (upesp+:func-with-clean-state
    (let ((p1 (upesp+:ensure-shell)))
      (process-send-string p1 "exit\n")
      (upesp+:test-wait (lambda () (not (process-live-p p1))) 5)
      (let ((p2 (upesp+:ensure-shell)))
        (should (not (eq p1 p2)))
        (should (upesp+:shell-live-p))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Command execution

(ert-deftest upesp+:func/single-command-runs ()
  "A single command executes and its output appears in the installer buffer."
  (upesp+:func-with-clean-state
    (when-let ((buf (get-buffer upesp+:shell-buffer)))
      (kill-buffer buf))
    (upesp+:async-shell-command "echo hello-upesp-test")
    (should
     (upesp+:test-wait
      (lambda ()
        (string-match "hello-upesp-test" (or (upesp+:test-shell-output) "")))
      10))))

(ert-deftest upesp+:func/commands-run-sequentially ()
  "Multiple commands run in FIFO order."
  (upesp+:func-with-clean-state
    (when-let ((buf (get-buffer upesp+:shell-buffer)))
      (kill-buffer buf))
    (upesp+:async-shell-command "echo STEP1")
    (upesp+:async-shell-command "echo STEP2")
    (upesp+:async-shell-command "echo STEP3")
    (should
     (upesp+:test-wait
      (lambda ()
        (let ((out (or (upesp+:test-shell-output) "")))
          (and (string-match "STEP1" out)
               (string-match "STEP2" out)
               (string-match "STEP3" out)
               (< (string-match "STEP1" out)
                  (string-match "STEP2" out)
                  (string-match "STEP3" out)))))
      10))))

(ert-deftest upesp+:func/duplicate-commands-run-once ()
  "The same install command is not executed twice."
  (upesp+:func-with-clean-state
    (when-let ((buf (get-buffer upesp+:shell-buffer)))
      (kill-buffer buf))
    (upesp+:async-shell-command "echo UNIQUE-MARKER")
    (upesp+:async-shell-command "echo UNIQUE-MARKER")
    (upesp+:test-wait
     (lambda () (not upesp+:command-occupied)) 10)
    (let* ((out (or (upesp+:test-shell-output) ""))
           (count (cl-count-if
                   (lambda (line) (string-match "UNIQUE-MARKER" line))
                   (split-string out "\n"))))
      (should (= 1 count)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Shell lifecycle after queue drains

(ert-deftest upesp+:func/shell-closes-after-queue-drains ()
  "Shell process exits automatically once all commands are done."
  (upesp+:func-with-clean-state
    (upesp+:async-shell-command "echo drain-test")
    (should
     (upesp+:test-wait
      (lambda () (not (upesp+:shell-live-p)))
      10))))

(ert-deftest upesp+:func/shell-reopens-for-new-commands ()
  "After draining and closing, new commands reopen the shell and run."
  (upesp+:func-with-clean-state
    (when-let ((buf (get-buffer upesp+:shell-buffer)))
      (kill-buffer buf))
    ;; First batch
    (upesp+:async-shell-command "echo FIRST-BATCH")
    (upesp+:test-wait (lambda () (not (upesp+:shell-live-p))) 10)
    ;; Second batch after shell has closed
    (upesp+:async-shell-command "echo SECOND-BATCH")
    (should
     (upesp+:test-wait
      (lambda ()
        (string-match "SECOND-BATCH" (or (upesp+:test-shell-output) "")))
      10))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Sentinel mechanism

(ert-deftest upesp+:func/sentinel-counter-increments ()
  "Each dispatched command increments the sentinel counter."
  (upesp+:func-with-clean-state
    (let ((before upesp+:sentinel-counter))
      (upesp+:async-shell-command "echo sentinel-count-test")
      (upesp+:test-wait (lambda () (> upesp+:sentinel-counter before)) 5)
      (should (> upesp+:sentinel-counter before)))))

(ert-deftest upesp+:func/occupied-cleared-after-command ()
  "command-occupied is nil once a command finishes."
  (upesp+:func-with-clean-state
    (upesp+:async-shell-command "echo occupied-test")
    (should
     (upesp+:test-wait (lambda () (not upesp+:command-occupied)) 10))))

;;; test-functional.el ends here
