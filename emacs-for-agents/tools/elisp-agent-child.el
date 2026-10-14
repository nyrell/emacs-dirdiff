;;; elisp-agent-child.el --- The parts of elisp-agent that run in a clean Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; `elisp-agent' starts a fresh `emacs --batch -Q' for compiling,
;; describing, evaluating and testing, and loads this file there.  The
;; results must be those of a clean Emacs, so this file loads no
;; library and uses only functions that are always loaded: no cl-lib,
;; no subr-x, no pcase.  Each function ends Emacs with the exit status
;; 0 (all is well) or 1.

;;; Code:

(defvar elisp-agent-child--failed nil "Non-nil once something has failed.")

(defun elisp-agent-child--say (format-string &rest args)
  "Print FORMAT-STRING with ARGS on a line of its own to standard output."
  (princ (concat (apply #'format format-string args) "\n")))

(defun elisp-agent-child--fail (format-string &rest args)
  "Print FORMAT-STRING with ARGS and remember the failure."
  (setq elisp-agent-child--failed t)
  (apply #'elisp-agent-child--say format-string args))

(defun elisp-agent-child--exit ()
  "End Emacs with status 1 after a failure, 0 otherwise."
  (kill-emacs (if elisp-agent-child--failed 1 0)))

;;;; compile

(defvar byte-compile-dest-file-function)
(defvar byte-compile-log-buffer)

(defun elisp-agent-child-compile (file allow-warnings)
  "Byte-compile FILE; warnings fail unless ALLOW-WARNINGS."
  ;; Load bytecomp before binding its variables, or the binding is lexical.
  (require 'bytecomp)
  (let* ((dest (make-temp-file "elisp-agent-" nil ".elc"))
         (byte-compile-dest-file-function (lambda (_) dest))
         (load-path (cons (file-name-directory file) load-path)))
    (unwind-protect
        (if (not (byte-compile-file file))
            (elisp-agent-child--fail "%s: byte-compilation failed (see the messages above)" file)
          (let ((warnings (with-current-buffer (get-buffer-create byte-compile-log-buffer)
                            (count-matches "Warning" (point-min) (point-max)))))
            (when (and (> warnings 0) (not allow-warnings))
              (elisp-agent-child--fail "%s: %d compiler warning(s) (see the messages above)"
                                       file warnings))))
      (delete-file dest)))
  (elisp-agent-child--exit))

;;;; describe

(defconst elisp-agent-child--libraries
  '(subr-x cl-lib seq map rx thingatpt text-property-search ring json
           let-alist url-util dom xml project ert)
  "Libraries to try when a symbol is not defined in a clean Emacs.")

(defconst elisp-agent-child--packages
  '(("s-" . "s.el") ("f-" . "f.el") ("ht-" . "ht.el") ("-" . "dash.el")
    ("dash-" . "dash.el"))
  "Name prefixes of popular packages that are not part of Emacs.")

(defconst elisp-agent-child--instead
  '((s-trim . string-trim) (s-join . string-join) (s-split . split-string)
    (s-starts-with\? . string-prefix-p) (s-ends-with\? . string-suffix-p)
    (s-contains\? . string-search) (s-replace . string-replace)
    (s-blank\? . string-empty-p) (s-lines . string-lines)
    (f-join . file-name-concat) (f-exists\? . file-exists-p)
    (f-filename . file-name-nondirectory) (f-dirname . file-name-directory)
    (f-ext . file-name-extension) (f-no-ext . file-name-sans-extension)
    (-map . mapcar) (-filter . seq-filter) (-remove . seq-remove)
    (-reduce . seq-reduce) (-first . seq-find) (-uniq . seq-uniq)
    (-flatten . flatten-tree) (ht-get . gethash) (ht-set! . puthash))
  "Built-in replacements for common functions from those packages.")

(defun elisp-agent-child--first-line (doc)
  "Return the first line of docstring DOC."
  (if doc (car (split-string doc "\n")) "(no documentation)"))

(defun elisp-agent-child--similar (name)
  "Defined symbols whose names are close to NAME.
That is, names a few edits away, and defined tails of NAME: for
\"string-length\" that finds \"length\"."
  (let ((parts (split-string name "-" t))
        found)
    (while (cdr parts)
      (setq parts (cdr parts))
      (let ((tail (intern-soft (mapconcat #'identity parts "-"))))
        (when (and tail (fboundp tail)) (push (symbol-name tail) found))))
    (mapatoms (lambda (s)
                (when (and (or (fboundp s) (boundp s))
                           (not (keywordp s))
                           (let ((n (symbol-name s)))
                             (and (< (abs (- (length n) (length name))) 4)
                                  (<= (string-distance n name)
                                      (if (< (length name) 6) 1 2)))))
                  (push (symbol-name s) found))))
    (sort (delete-dups found) #'string<)))

(defun elisp-agent-child--usage (sym)
  "Return how SYM is called, like \"(if COND THEN ELSE...)\", and its doc."
  (let* ((doc (ignore-errors (documentation sym t)))
         (split (and doc (help-split-fundoc doc sym))))
    (cons (or (car split)
              (let ((args (help-function-arglist sym t)))
                (if (listp args)
                    (format "(%s%s)" sym
                            (mapconcat (lambda (arg)
                                         (if (memq arg '(&optional &rest))
                                             (format " %s" arg)
                                           (format " %s" (upcase (symbol-name arg)))))
                                       args ""))
                  (format "(%s ...)" sym))))
          (if split (cdr split) doc))))

(defun elisp-agent-child--obsolete (info)
  "Describe the obsolescence INFO of a function or variable."
  (let ((new (car info)) (when (nth 2 info)))
    (format "  OBSOLETE%s: %s" (if when (format " since %s" when) "")
            (if (stringp new) new (format "use `%s' instead." new)))))

(defun elisp-agent-child--describe-function (sym)
  "Print what SYM is as a function."
  (let* ((usage (elisp-agent-child--usage sym))
         (file (symbol-file sym 'defun)))
    (elisp-agent-child--say "%s: %s %s" sym
                            (cond ((special-form-p sym) "special form")
                                  ((macrop sym) "macro")
                                  ((commandp sym) "command")
                                  (t "function"))
                            (car usage))
    (elisp-agent-child--say "  %s" (elisp-agent-child--first-line (cdr usage)))
    (when file (elisp-agent-child--say "  defined in %s" file))
    (let ((news (elisp-agent-child--news (symbol-name sym))))
      (when news (elisp-agent-child--say "  first in NEWS: %s" news)))
    (let ((obsolete (get sym 'byte-obsolete-info)))
      (when obsolete (elisp-agent-child--say "%s" (elisp-agent-child--obsolete obsolete))))))

(defun elisp-agent-child--describe-variable (sym)
  "Print what SYM is as a variable, with its value shortened."
  (let* ((value (let ((print-length 10) (print-level 3))
                  (format "%S" (symbol-value sym))))
         (short (if (> (length value) 200) (concat (substring value 0 200) " ...") value)))
    (elisp-agent-child--say "%s: variable, value %s" sym short)
    (elisp-agent-child--say "  %s" (elisp-agent-child--first-line
                                    (documentation-property sym 'variable-documentation t)))
    (let ((obsolete (get sym 'byte-obsolete-variable)))
      (when obsolete (elisp-agent-child--say "%s" (elisp-agent-child--obsolete obsolete))))))

(defun elisp-agent-child--news (name)
  "Return the first NEWS heading that mentions NAME, like \"Emacs 28: ...\".
NEWS.N lists the changes in Emacs N, and NEWS those of this version.
A mention in a heading usually means the symbol is new or changed."
  (let ((pattern (concat "^\\*+ .*['`]" (regexp-quote name) "'"))
        (found nil)
        (version 18))
    (while (and (not found) (<= version emacs-major-version))
      (let ((file (expand-file-name (if (= version emacs-major-version)
                                        "NEWS"
                                      (format "NEWS.%d" version))
                                    data-directory)))
        (when (file-readable-p file)
          (with-temp-buffer
            (insert-file-contents file)
            (when (re-search-forward pattern nil t)
              (setq found (format "Emacs %d: %s" version
                                  (buffer-substring-no-properties
                                   (line-beginning-position) (line-end-position))))))))
      (setq version (1+ version)))
    found))

(defun elisp-agent-child--package-hint (name)
  "Return a hint if NAME seems to come from a popular package, else nil."
  (let ((hint nil))
    (dolist (entry elisp-agent-child--packages)
      (when (and (not hint) (string-prefix-p (car entry) name))
        (let ((instead (cdr (assq (intern name) elisp-agent-child--instead))))
          (setq hint (format "  %s looks like %s, a package that is not part of Emacs.%s"
                             name (cdr entry)
                             (if instead (format " Built in: %s" instead) ""))))))
    hint))

(defun elisp-agent-child-describe (name)
  "Describe the symbol called NAME as a clean Emacs sees it."
  (let ((sym (intern-soft name)))
    (if (and sym (or (fboundp sym) (boundp sym)))
        (progn
          (when (fboundp sym)
            (when (autoloadp (symbol-function sym))
              (elisp-agent-child--say "%s: autoloaded, no require needed" name)
              (ignore-errors (autoload-do-load (symbol-function sym) sym)))
            (elisp-agent-child--describe-function sym))
          (when (boundp sym)
            (elisp-agent-child--describe-variable sym)))
      ;; Not defined: maybe a library defines it, maybe it is invented.
      (let ((similar (elisp-agent-child--similar name))
            (library nil))
        (dolist (lib elisp-agent-child--libraries)
          (unless library
            (require lib nil t)
            (setq sym (intern-soft name))
            (when (and sym (or (fboundp sym) (boundp sym)))
              (setq library lib))))
        (if library
            (progn
              (elisp-agent-child--fail "%s: NOT DEFINED in a clean Emacs; add (require '%s)"
                                       name library)
              (if (fboundp sym)
                  (elisp-agent-child--describe-function sym)
                (elisp-agent-child--describe-variable sym)))
          (elisp-agent-child--fail "%s: NOT DEFINED%s" name
                                   (if similar
                                       (format "  Similar: %s" (mapconcat #'identity similar " "))
                                     ""))
          (let ((hint (elisp-agent-child--package-hint name)))
            (when hint (elisp-agent-child--say "%s" hint)))))))
  (elisp-agent-child--exit))

;;;; builtins

(defvar shortdoc--groups)

(defun elisp-agent-child-builtins (group)
  "List the functions of the shortdoc GROUP, or the groups if GROUP is nil."
  (let ((clean (let (names)
                 (mapatoms (lambda (s) (when (fboundp s) (push s names))))
                 names)))
    (require 'shortdoc)
    (let ((items (and group (cdr (assq (intern group) shortdoc--groups))))
          (groups (mapconcat (lambda (g) (symbol-name (car g))) shortdoc--groups " ")))
      (cond
       ((null group)
        (elisp-agent-child--say "Groups: %s\nUse: elisp-agent builtins GROUP" groups))
       ((null items)
        (elisp-agent-child--fail "%s: no such group. Groups: %s" group groups))
       (t
        ;; Some of them need a library; load the usual ones to find out which.
        (dolist (lib elisp-agent-child--libraries) (require lib nil t))
        (dolist (item items)
          (cond ((stringp item) (elisp-agent-child--say "\n;; %s" item))
                ((and (consp item) (symbolp (car item)) (fboundp (car item)))
                 (let ((sym (car item)))
                   (elisp-agent-child--say
                    "%-32s %s%s" sym
                    (elisp-agent-child--first-line (cdr (elisp-agent-child--usage sym)))
                    (if (memq sym clean)
                        ""
                      (let ((lib (file-name-base (or (symbol-file sym 'defun) "?"))))
                        ;; cl-extra, cl-seq and cl-macs are loaded through cl-lib.
                        (format "  [needs (require '%s)]"
                                (if (string-prefix-p "cl-" lib) "cl-lib" lib)))))))))))))
  (elisp-agent-child--exit))

;;;; eval

(defun elisp-agent-child-eval (text)
  "Evaluate each expression in TEXT and print its value or its error."
  (let ((pos 0)
        (print-length 100)
        (print-level 10))
    (condition-case err
        (while (string-match-p "[^ \t\n]" (substring text pos))
          (let ((read (read-from-string text pos)))
            (setq pos (cdr read))
            (condition-case err
                (elisp-agent-child--say "%S" (eval (car read) t))
              (error (elisp-agent-child--fail "ERROR: %s" (error-message-string err))))))
      (error (elisp-agent-child--fail "ERROR: cannot read the expression: %s"
                                      (error-message-string err)))))
  (elisp-agent-child--exit))

;;;; test

(declare-function ert-run-tests-batch "ert" (&optional selector))
(declare-function ert-stats-total "ert" (stats))
(declare-function ert-stats-completed-unexpected "ert" (stats))

(defun elisp-agent-child-test (selector)
  "Run ERT with SELECTOR on what has been loaded."
  (let ((stats (ert-run-tests-batch selector)))
    (cond
     ((zerop (ert-stats-total stats))
      (elisp-agent-child--fail "No tests ran: none were loaded%s"
                               (if (stringp selector)
                                   (format ", or none match \"%s\"" selector)
                                 "")))
     ((> (ert-stats-completed-unexpected stats) 0)
      (setq elisp-agent-child--failed t))))
  (elisp-agent-child--exit))

(provide 'elisp-agent-child)
;;; elisp-agent-child.el ends here
