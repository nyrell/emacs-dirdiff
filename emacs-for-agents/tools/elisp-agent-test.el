;;; elisp-agent-test.el --- Tests for elisp-agent  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run the tests from the repository root with:
;; `emacs --batch -Q -L emacs-for-agents/tools
;;    -l emacs-for-agents/tools/elisp-agent-test.el -f ert-run-tests-batch-and-exit'

;;; Code:

(require 'ert)
(require 'elisp-agent)

(defun elisp-agent-test--run (fn source &rest args)
  "Write SOURCE to a file, call FN with it, return (OUTPUT . FAILED)."
  (let ((file (make-temp-file "elisp-agent-test-" nil ".el" source))
        (elisp-agent--failed nil))
    (unwind-protect
        (let ((output (with-output-to-string
                        (funcall fn (append args (list file))))))
          (cons (replace-regexp-in-string (regexp-quote file) "F" output)
                elisp-agent--failed))
      (delete-file file))))

(ert-deftest elisp-agent-test-missing-paren ()
  (should (equal (elisp-agent-test--run
                  #'elisp-agent-check
                  "(defun a ()\n  (let ((x 1))\n    x)\n\n(defun b () 2)\n")
                 '("F:1: missing 1 closing paren(s) in the form starting at line 1: (defun a ... (line 5 starts a new top-level form inside it) Hint: the indentation agrees with the parens, so the ) is probably missing at the end of line 3.\n" . t))))

(ert-deftest elisp-agent-test-missing-paren-hint ()
  "Indentation that disagrees with the parens points at the mistake."
  (should (string-match-p
           "Hint: line 3 is indented 4, but the parens put it at 8, so a ) is probably missing at the end of the code before line 3\\."
           (car (elisp-agent-test--run
                 #'elisp-agent-check
                 "(defun a (x)\n  (let ((y (1+ x))\n    (when y\n      y)\n    y))\n\n(defun b () 2)\n")))))

(ert-deftest elisp-agent-test-missing-paren-at-end ()
  (should (equal (elisp-agent-test--run #'elisp-agent-check "(defun a ()\n  (list 1\n")
                 '("F:1: missing closing paren(s): this form is not closed before the end of the file: (defun a Hint: the indentation agrees with the parens, so the ) is probably missing at the end of line 2.\n" . t))))

(ert-deftest elisp-agent-test-extra-paren ()
  (should (equal (elisp-agent-test--run #'elisp-agent-check "(defun a () 1))\n(defun b () 2)\n")
                 '("F:1: extra closing paren; the form starting at line 1 has one ) too many: (defun a\n" . t))))

(ert-deftest elisp-agent-test-closed-too-early ()
  (should (equal (elisp-agent-test--run #'elisp-agent-check "(defun a ()\n  (foo))\n  (bar))\n(defun b () 2)\n")
                 '("F:3: extra closing paren; an earlier form was closed too early, so the indented form at line 3 ended up at top level: (bar Hint: line 3 is indented 2, but the parens put it at 0, so there is probably a ) too many before line 3.\n" . t))))

(ert-deftest elisp-agent-test-parens-in-strings-and-comments ()
  (should-not (cdr (elisp-agent-test--run
                    #'elisp-agent-check
                    ";;; -*- lexical-binding: t; -*-\n;; (not code\n(defun a ()\n  \"Doc (with a paren.\n\\(at column 0) too.\"\n  ?\\( 1)\n"))))

(ert-deftest elisp-agent-test-indent ()
  (should (equal (elisp-agent-test--run #'elisp-agent-indent "(defun a ()\n  (when t\n  1))\n")
                 '("F:3: indentation 2, expected 4: 1))\n" . t)))
  ;; Deep lines: Emacs would use tabs, which must not count as one column.
  (should (equal (elisp-agent-test--run
                  #'elisp-agent-indent
                  "(defun a ()\n  (when t\n    (when t\n      (when t\n    1))))\n")
                 '("F:5: indentation 4, expected 8: 1))))\n" . t))))

(ert-deftest elisp-agent-test-describe ()
  (let ((elisp-agent--failed nil))
    (should (string-match-p "Similar: length"
                            (with-output-to-string (elisp-agent-describe '("string-length")))))
    (should elisp-agent--failed)))

(ert-deftest elisp-agent-test-regexp ()
  "Perl habits in regexps are reported (needs relint, from --packages)."
  (skip-unless (require 'relint nil t))
  (let ((result (elisp-agent-test--run
                 #'elisp-agent-check
                 ";;; -*- lexical-binding: t; -*-\n(defun a (s) (string-match \"\\\\s+x\" s))\n"
                 "--regexp")))
    (should (cdr result))
    (should (string-match-p "F:2: .*Unknown syntax code" (car result)))))

(defconst elisp-agent-test--manual
  (concat "\^_\nFile: mini.info,  Node: Top,  Next: Hooks,  Up: (dir)\n\n"
          "Mini manual\n\n* Menu:\n\n* Hooks::\n* Index::\n\n"
          "\^_\nFile: mini.info,  Node: Hooks,  Next: Index,  Prev: Top,  Up: Top\n\n"
          "Hooks\n=====\n\nUse add-hook to add a function.\n\n"
          "\^_\nFile: mini.info,  Node: Index,  Prev: Hooks,  Up: Top\n\n"
          "\0\b[index\0\b]\n* Menu:\n\n"
          "* add-hook:                              Hooks.               (line 6)\n\n\^_\n")
  "A tiny Info manual with a Top, a Hooks and an Index node.")

(ert-deftest elisp-agent-test-info ()
  (let* ((file (make-temp-file "elisp-agent-test-" nil ".info" elisp-agent-test--manual))
         (run (lambda (&rest args)
                (let ((elisp-agent--failed nil))
                  (cons (replace-regexp-in-string
                         (regexp-quote file) "M"
                         (with-output-to-string (elisp-agent-info args)))
                        elisp-agent--failed)))))
    (unwind-protect
        (progn
          (should (string-match-p "\\`File: mini.info,  Node: Hooks.*\n\nHooks\n=====\n\nUse add-hook"
                                  (car (funcall run file "Hooks"))))
          (should (string-match-p "Node: Hooks" (car (funcall run (format "(%s) Hooks" file)))))
          (should (equal (funcall run "--index" file "add-hook")
                         '("add-hook: (M) Hooks, line 6\n" . nil)))
          (should (cdr (funcall run "--index" file "remove-hook")))
          (should (equal (funcall run "--search" file "a function")
                         '("(M) Hooks: Use add-hook to add a function.\n" . nil)))
          (should (string-match-p "not installed.*\n.*/html_node/no-such-manual/M_002dx\\.html"
                                  (car (funcall run "no-such-manual" "M-x")))))
      (delete-file file))))

(provide 'elisp-agent-test)
;;; elisp-agent-test.el ends here
