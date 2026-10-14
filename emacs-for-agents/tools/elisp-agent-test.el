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
                 '("F:1: missing 1 closing paren(s) in the form starting at line 1: (defun a ... (line 5 starts a new top-level form inside it)\n" . t))))

(ert-deftest elisp-agent-test-missing-paren-at-end ()
  (should (equal (elisp-agent-test--run #'elisp-agent-check "(defun a ()\n  (list 1\n")
                 '("F:1: missing closing paren(s): this form is not closed before the end of the file: (defun a\n" . t))))

(ert-deftest elisp-agent-test-extra-paren ()
  (should (equal (elisp-agent-test--run #'elisp-agent-check "(defun a () 1))\n(defun b () 2)\n")
                 '("F:1: extra closing paren; the form starting at line 1 has one ) too many: (defun a\n" . t))))

(ert-deftest elisp-agent-test-parens-in-strings-and-comments ()
  (should-not (cdr (elisp-agent-test--run
                    #'elisp-agent-check
                    ";;; -*- lexical-binding: t; -*-\n;; (not code\n(defun a ()\n  \"Doc (with a paren.\n\\(at column 0) too.\"\n  ?\\( 1)\n"))))

(ert-deftest elisp-agent-test-indent ()
  (should (equal (elisp-agent-test--run #'elisp-agent-indent "(defun a ()\n  (when t\n  1))\n")
                 '("F:3: indentation 2, expected 4: 1))\n" . t))))

(ert-deftest elisp-agent-test-describe ()
  (let ((elisp-agent--failed nil))
    (should (string-match-p "Similar: length"
                            (with-output-to-string (elisp-agent-describe '("string-length")))))
    (should elisp-agent--failed)))

(provide 'elisp-agent-test)
;;; elisp-agent-test.el ends here
