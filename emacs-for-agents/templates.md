# Templates

Copy, rename `mypkg`, delete what you do not need. The package file (with
the mode added) and the test file pass `emacs-for-agents/tools/elisp-agent check --doc` and
`indent` as they are; check the test file with `-L .` so it finds the
package.

## Package file

```elisp
;;; mypkg.el --- Summary in a few words  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Your Name

;; Author: Your Name <you@example.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools
;; URL: https://example.com/mypkg

;;; Commentary:

;; What the package does and how to start it.

;;; Code:

(defgroup mypkg nil
  "What the package is for."
  :group 'tools
  :prefix "mypkg-")

(defcustom mypkg-separator ","
  "Separator between fields."
  :type 'string)

(defun mypkg--fields (string)
  "Split STRING into fields at `mypkg-separator'."
  (split-string string (regexp-quote mypkg-separator)))

;;;###autoload
(defun mypkg-count-fields (string)
  "Show how many fields STRING has."
  (interactive (list (read-string "String: ")))
  (message "%d fields" (length (mypkg--fields string))))

(provide 'mypkg)
;;; mypkg.el ends here
```

## Major mode for a read-only view

```elisp
(defvar-keymap mypkg-view-mode-map
  :doc "Keymap for `mypkg-view-mode'."
  :parent special-mode-map
  "RET" #'mypkg-view-open)

(define-derived-mode mypkg-view-mode special-mode "Mypkg"
  "Major mode for viewing mypkg results.

\\{mypkg-view-mode-map}"
  :interactive nil
  (setq truncate-lines t)
  (setq-local revert-buffer-function (lambda (&rest _) (mypkg-view-refresh))))

(defun mypkg-view-refresh ()
  "Redraw the current mypkg buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert "...")))

(defun mypkg-view-open ()
  "Open the item on the current line."
  (interactive)
  (message "Not written yet"))

;;;###autoload
(defun mypkg-view ()
  "Show the mypkg view."
  (interactive)
  (let ((buffer (get-buffer-create "*mypkg*")))
    (with-current-buffer buffer
      (mypkg-view-mode)
      (mypkg-view-refresh))
    (pop-to-buffer buffer)))
```

## Test file

```elisp
;;; mypkg-test.el --- Tests for mypkg  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run the tests with:
;; `emacs --batch -Q -L . -l test/mypkg-test.el -f ert-run-tests-batch-and-exit'

;;; Code:

(require 'ert)
(require 'mypkg)

(ert-deftest mypkg-test-fields ()
  (should (equal (mypkg--fields "a,b") '("a" "b")))
  (should (equal (mypkg--fields "") '(""))))

(ert-deftest mypkg-test-count-fields-message ()
  (let (shown)
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (setq shown (apply #'format fmt args)))))
      (mypkg-count-fields "a,b,c"))
    (should (equal shown "3 fields"))))

(provide 'mypkg-test)
;;; mypkg-test.el ends here
```
