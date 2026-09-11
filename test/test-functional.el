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
         (upesp+:command-ready nil)
         (upesp+:command-executing nil)
         (upesp+:command-cancelled nil)
         (upesp+:shell-process nil)
         (upesp+:shell-process-terminate-timer nil))
     (unwind-protect
         (progn ,@body)
       (when upesp+:shell-process-terminate-timer
         (cancel-timer upesp+:shell-process-terminate-timer)
         (setq upesp+:shell-process-terminate-timer nil))
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
  (when-let ((buf (and upesp+:shell-process (process-buffer upesp+:shell-process))))
    (with-current-buffer buf (buffer-string))))

(defun upesp+:test-kill-installer-buffers ()
  "Kill any leftover installer buffer, matching its dynamic renamed form too."
  (dolist (buf (buffer-list))
    (when (string-match-p "\\`\\*upesp\\+ installer\\(: .*\\)?\\*\\'" (buffer-name buf))
      (kill-buffer buf))))

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
    (upesp+:test-kill-installer-buffers)
    (upesp+:async-shell-command "echo hello-upesp-test")
    (should
     (upesp+:test-wait
      (lambda ()
        (string-match "hello-upesp-test" (or (upesp+:test-shell-output) "")))
      10))))

(ert-deftest upesp+:func/commands-run-sequentially ()
  "Multiple commands run in FIFO order."
  ;; Ordering is verified through upesp+:command-executed-hook firing order
  ;; rather than the installer buffer transcript, since the transcript's
  ;; own accumulation/separator behaviour is covered separately below.
  (upesp+:func-with-clean-state
    (let* ((executed nil)
           (hook-fn (lambda (cmd) (push cmd executed))))
      (add-hook 'upesp+:command-executed-hook hook-fn)
      (unwind-protect
          (progn
            (upesp+:async-shell-command "echo STEP1")
            (upesp+:async-shell-command "echo STEP2")
            (upesp+:async-shell-command "echo STEP3")
            (upesp+:test-wait (lambda () (= (length executed) 3)) 10)
            (should (equal (reverse executed)
                           '("echo STEP1" "echo STEP2" "echo STEP3"))))
        (remove-hook 'upesp+:command-executed-hook hook-fn)))))

(ert-deftest upesp+:func/installer-buffer-accumulates-with-separator ()
  "The installer buffer keeps every command's output, dash-separated."
  (upesp+:func-with-clean-state
    (upesp+:test-kill-installer-buffers)
    (upesp+:async-shell-command "echo ACCUM-STEP1")
    (upesp+:test-wait
     (lambda () (string-match-p "ACCUM-STEP1" (or (upesp+:test-shell-output) ""))) 10)
    (upesp+:async-shell-command "echo ACCUM-STEP2")
    (should
     (upesp+:test-wait
      (lambda () (string-match-p "ACCUM-STEP2" (or (upesp+:test-shell-output) ""))) 10))
    (let ((out (upesp+:test-shell-output)))
      ;; Both commands' output survived — the buffer was never erased.
      (should (string-match-p "ACCUM-STEP1" out))
      (should (string-match-p "ACCUM-STEP2" out))
      ;; A dash separator line sits between the two commands' sections.
      (should (string-match-p (regexp-quote (make-string 60 ?-)) out)))))

(ert-deftest upesp+:func/queue-entry-marker-points-into-installer-buffer ()
  "send-command records a marker on the queue entry once its log starts."
  (upesp+:func-with-clean-state
    (upesp+:test-kill-installer-buffers)
    (upesp+:async-shell-command "echo MARKER-TEST")
    (should
     (upesp+:test-wait
      (lambda () (string-match-p "MARKER-TEST" (or (upesp+:test-shell-output) ""))) 10))
    (let* ((entry (car upesp+:queue-entries))
           (marker (upesp+:queue-entry-marker entry)))
      (should (markerp marker))
      (should (eq (marker-buffer marker) (process-buffer upesp+:shell-process)))
      (with-current-buffer (marker-buffer marker)
        (should (string-match-p "\\`Executing command"
                                 (buffer-substring-no-properties
                                  marker (min (point-max) (+ marker 40)))))))))

(ert-deftest upesp+:func/duplicate-commands-run-once ()
  "The same install command is not executed twice."
  (upesp+:func-with-clean-state
    (upesp+:test-kill-installer-buffers)
    (upesp+:async-shell-command "echo UNIQUE-MARKER")
    (upesp+:async-shell-command "echo UNIQUE-MARKER")
    ;; Wait for the finalize timer to be set — that means the queue drained.
    (upesp+:test-wait
     (lambda () upesp+:shell-process-terminate-timer) 10)
    (let* ((out (or (upesp+:test-shell-output) ""))
           ;; Exclude the "Command succeeded/failed: <cmd>" summary line —
           ;; it echoes the full command text, which also contains the
           ;; marker, so counting it would double-count a single run.
           (count (cl-count-if
                   (lambda (line) (and (string-match "UNIQUE-MARKER" line)
                                       (not (string-prefix-p "Command " line))))
                   (split-string out "\n"))))
      (should (= 1 count)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Shell lifecycle after queue drains

(ert-deftest upesp+:func/shell-schedules-finalize-after-queue-drains ()
  "After all commands finish, finalize timer is set and shell remains alive."
  (upesp+:func-with-clean-state
    (upesp+:async-shell-command "echo drain-test")
    (should
     (upesp+:test-wait
      (lambda () upesp+:shell-process-terminate-timer)
      10))
    (should (upesp+:shell-live-p))))

(ert-deftest upesp+:func/shell-reused-for-commands-within-alive-window ()
  "New commands submitted while shell is still alive after draining run on the same shell."
  (upesp+:func-with-clean-state
    (upesp+:test-kill-installer-buffers)
    ;; First batch — wait until queue drains (finalize timer set).
    (upesp+:async-shell-command "echo FIRST-BATCH")
    (upesp+:test-wait (lambda () upesp+:shell-process-terminate-timer) 10)
    (let ((first-proc upesp+:shell-process))
      ;; Submit second batch while shell is still alive; timer should be cancelled.
      (upesp+:async-shell-command "echo SECOND-BATCH")
      (should
       (upesp+:test-wait
        (lambda ()
          (string-match "SECOND-BATCH" (or (upesp+:test-shell-output) "")))
        10))
      ;; Same shell process must have been reused.
      (should (eq first-proc upesp+:shell-process)))))

(ert-deftest upesp+:func/shell-terminated-after-scheduled-finalize ()
  "Shell is terminated when the finalize timer is expired."
  (upesp+:func-with-clean-state
   (let ((upesp+:shell-process-expiry 5))
     (upesp+:async-shell-command "echo drain-test")
     (upesp+:test-wait (lambda () upesp+:shell-process-terminate-timer) 10)
     (should
      (upesp+:test-wait
       (lambda () (null upesp+:shell-process-terminate-timer)) 10))
     (should (not (upesp+:shell-live-p))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Shell prompt detection

(ert-deftest upesp+:func/occupied-cleared-after-command ()
  "command-occupied is nil once a command finishes."
  (upesp+:func-with-clean-state
    (upesp+:async-shell-command "echo occupied-test")
    (should
     (upesp+:test-wait (lambda () (not upesp+:command-occupied)) 10))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; upesp+:command-executed-hook

(ert-deftest upesp+:func/hook-called-for-each-command ()
  "command-executed-hook fires once per completed command with the cmd string."
  (upesp+:func-with-clean-state
    (let* ((executed nil)
           (hook-fn (lambda (cmd) (push cmd executed))))
      (add-hook 'upesp+:command-executed-hook hook-fn)
      (unwind-protect
          (progn
            (upesp+:async-shell-command "echo HOOK-A")
            (upesp+:async-shell-command "echo HOOK-B")
            (upesp+:test-wait (lambda () (= (length executed) 2)) 10)
            (should (member "echo HOOK-A" executed))
            (should (member "echo HOOK-B" executed)))
        (remove-hook 'upesp+:command-executed-hook hook-fn)))))

(ert-deftest upesp+:func/same-command-reruns-after-completion ()
  "Submitting the same command after it has run executes it again."
  ;; Verified via how many times upesp+:command-executed-hook fired for
  ;; this command, which is unambiguous regardless of buffer content.
  (upesp+:func-with-clean-state
    (let* ((executed-count 0)
           (hook-fn (lambda (cmd)
                      (when (equal cmd "echo RERUN-MARKER")
                        (cl-incf executed-count)))))
      (add-hook 'upesp+:command-executed-hook hook-fn)
      (unwind-protect
          (progn
            (upesp+:async-shell-command "echo RERUN-MARKER")
            ;; Wait for queue to drain before re-submitting.
            (upesp+:test-wait (lambda () upesp+:shell-process-terminate-timer) 10)
            (upesp+:async-shell-command "echo RERUN-MARKER")
            (should (upesp+:test-wait (lambda () (= executed-count 2)) 10)))
        (remove-hook 'upesp+:command-executed-hook hook-fn)))))

;;; test-functional.el ends here
