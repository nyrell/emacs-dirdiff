;;; elisp-agent.el --- Batch checks for coding agents writing Emacs Lisp  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run through the `elisp-agent' shell script; see ../tools.md.
;;
;;   elisp-agent check [--doc] [--regexp] [--allow-warnings] FILE...
;;                                   structure, byte-compile, checkdoc, relint
;;   elisp-agent forms FILE                        top-level forms and their lines
;;   elisp-agent indent [--fix] FILE...            lines Emacs would indent differently
;;   elisp-agent describe SYMBOL...                exists? arguments, docstring
;;   elisp-agent builtins [GROUP]                  built-in functions by topic
;;   elisp-agent info [MANUAL [NODE]]              read Info manuals (also --index, --search)
;;   elisp-agent eval EXPRESSION                   evaluate, print the result
;;   elisp-agent test FILE... [-s SELECTOR]        run ERT tests
;;
;; Common options: -L DIR (add to load-path), -l FILE (load),
;; --require FEATURE, --packages (initialize installed packages).
;; (Not -r: Emacs itself takes -r, reverse video, from the command line.)
;;
;; Output is one finding per line, as FILE:LINE: MESSAGE where possible.
;; The exit status is 0 when everything is fine and 1 otherwise.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
;; Load libraries before let-binding their variables; otherwise the
;; binding is lexical and has no effect (or is an error).
(require 'bytecomp)
(require 'checkdoc)
(require 'warnings)                     ; before mocking display-warning
(require 'info)

(defvar elisp-agent--failed nil "Non-nil once a check has failed.")

(defun elisp-agent--say (format-string &rest args)
  "Print FORMAT-STRING with ARGS on a line of its own to standard output."
  (princ (concat (apply #'format format-string args) "\n")))

(defun elisp-agent--fail (format-string &rest args)
  "Print FORMAT-STRING with ARGS as a finding and remember the failure."
  (setq elisp-agent--failed t)
  (apply #'elisp-agent--say format-string args))

;;;; Options

(defun elisp-agent--parse-options (args)
  "Handle the common options in ARGS; return the remaining arguments."
  (let (rest)
    (while args
      (let ((arg (pop args)))
        (pcase arg
          ("-L" (push (expand-file-name (pop args)) load-path))
          ("-l" (load (expand-file-name (pop args)) nil t))
          ("--require" (require (intern (pop args))))
          ("--packages" (require 'package)
           (when-let* ((dir (getenv "ELISP_AGENT_PACKAGE_DIR")))
             (setq package-user-dir dir))
           (package-initialize))
          (_ (push arg rest)))))
    (nreverse rest)))

;;;; check

(defun elisp-agent--line (pos)
  "Return the line number of POS."
  (line-number-at-pos pos t))

(defun elisp-agent--form-name (pos)
  "A short description of the form starting at POS, like \"(defun foo\"."
  (save-excursion
    (goto-char pos)
    (buffer-substring-no-properties
     pos (min (pos-eol) (save-excursion (forward-char 1)
                                        (ignore-errors (forward-sexp 1) (forward-sexp 1))
                                        (point))))))

(defun elisp-agent--indent-hint (beg end &optional missing)
  "Say where the indentation between BEG and END disagrees with the parens.
Models indent by intention more reliably than they count parens, so
the first disagreement is usually just after the mistake.  Return a
sentence starting with a space.  If the indentation agrees, return
\"\", or with MISSING, say the paren belongs at the end of the code."
  (let* ((text (buffer-substring-no-properties beg end))
         (first-line (elisp-agent--line beg))
         (before (split-string text "\n"))
         (after (with-temp-buffer
                  (insert text)
                  (emacs-lisp-mode)
                  (setq indent-tabs-mode nil) ; a tab would count as one column
                  (let ((inhibit-message t))
                    (indent-region (point-min) (point-max)))
                  (split-string (buffer-string) "\n"))))
    (or (cl-loop for old in before
                 for new in after
                 for line from first-line
                 for written = (- (length old) (length (string-trim-left old)))
                 for expected = (- (length new) (length (string-trim-left new)))
                 unless (or (= written expected) (string-blank-p old))
                 return (format " Hint: line %d is indented %d, but the parens put it at %d, so %s."
                                line written expected
                                (if (> expected written)
                                    (format "a ) is probably missing at the end of the code before line %d" line)
                                  (format "there is probably a ) too many before line %d" line))))
        (if (not missing)
            ""
          (format " Hint: the indentation agrees with the parens, so the ) is probably missing at the end of line %d."
                  (save-excursion
                    (goto-char end)
                    (skip-chars-backward " \t\n")
                    (elisp-agent--line (point))))))))

(defun elisp-agent--check-structure (file)
  "Report unbalanced parentheses in FILE, in words.  Return non-nil if OK."
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (let ((ok t))
      ;; A definition at column 0 that is nested inside another form
      ;; almost always means the form before it lacks closing parens.
      (goto-char (point-min))
      (while (re-search-forward "^(" nil t)
        (let* ((pos (match-beginning 0))
               ;; `syntax-ppss' moves point to POS.
               (ppss (save-excursion (syntax-ppss pos))))
          (when (and (> (nth 0 ppss) 0) (not (nth 3 ppss)) (not (nth 4 ppss)))
            (let ((outer (car (nth 9 ppss))))
              (setq ok nil)
              (elisp-agent--fail
               "%s:%d: missing %d closing paren(s) in the form starting at line %d: %s ... (line %d starts a new top-level form inside it)%s"
               file (elisp-agent--line outer) (nth 0 ppss) (elisp-agent--line outer)
               (elisp-agent--form-name outer) (elisp-agent--line pos)
               (elisp-agent--indent-hint outer pos t))))))
      ;; Walk the top-level forms; a scan error pinpoints the rest.
      (goto-char (point-min))
      (let ((previous nil))
        (while (and ok (progn (forward-comment (buffer-size)) (not (eobp))))
          (let ((start (point)))
            (cond
             ((looking-at-p ")")
              (setq ok nil)
              (elisp-agent--fail "%s:%d: extra closing paren%s%s"
                                 file (elisp-agent--line start)
                                 (cond
                                  ((null previous) "")
                                  ;; An indented form at top level: a form
                                  ;; above it was closed too early.
                                  ((save-excursion (goto-char previous) (not (bolp)))
                                   (format "; an earlier form was closed too early, so the indented form at line %d ended up at top level: %s"
                                           (elisp-agent--line previous)
                                           (elisp-agent--form-name previous)))
                                  (t
                                   (format "; the form starting at line %d has one ) too many: %s"
                                           (elisp-agent--line previous)
                                           (elisp-agent--form-name previous))))
                                 (elisp-agent--indent-hint
                                  (save-excursion
                                    (if (re-search-backward "^(" nil t) (point) (point-min)))
                                  start)))
             ((condition-case nil (progn (forward-sexp 1) t) (scan-error nil))
              (setq previous start))
             (t
              (setq ok nil)
              (elisp-agent--fail "%s:%d: missing closing paren(s): this form is not closed before the end of the file: %s%s"
                                 file (elisp-agent--line start)
                                 (elisp-agent--form-name start)
                                 (elisp-agent--indent-hint start (point-max) t)))))))
      ok)))

(defun elisp-agent--byte-compile (file allow-warnings)
  "Byte-compile FILE, printing warnings.
Warnings count as failures unless ALLOW-WARNINGS."
  (let* ((dest (make-temp-file "elisp-agent-" nil ".elc"))
         (byte-compile-dest-file-function (lambda (_) dest))
         (load-path (cons (file-name-directory (expand-file-name file)) load-path)))
    (when (get-buffer byte-compile-log-buffer)
      (kill-buffer byte-compile-log-buffer))
    (unwind-protect
        (if (not (byte-compile-file file))
            (elisp-agent--fail "%s: byte-compilation failed (see the messages above)" file)
          (let ((warnings (with-current-buffer (get-buffer-create byte-compile-log-buffer)
                            (count-matches "Warning" (point-min) (point-max)))))
            (when (and (> warnings 0) (not allow-warnings))
              (elisp-agent--fail "%s: %d compiler warning(s) (see the messages above)"
                                 file warnings))))
      (delete-file dest))))

(defun elisp-agent--checkdoc (file)
  "Run checkdoc on FILE and report its findings."
  ;; In batch mode checkdoc reports through `display-warning'.
  (let (findings)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &rest _) (push message findings))))
      (checkdoc-file file))
    (dolist (finding (nreverse findings))
      (elisp-agent--fail "%s (checkdoc)" (string-trim finding)))))

(declare-function relint-buffer "ext:relint" (buffer))

(defun elisp-agent--relint (file)
  "Report regexp mistakes in FILE, as found by relint."
  (if (not (require 'relint nil t))
      (elisp-agent--fail "%s: relint is not installed; install it from GNU ELPA and add --packages" file)
    (with-temp-buffer
      (insert-file-contents file)
      (emacs-lisp-mode)
      ;; A diagnostic is a vector: [MESSAGE BEG-POS END-POS POS-TYPE STRING ...].
      (dolist (diag (relint-buffer (current-buffer)))
        (elisp-agent--fail "%s:%d: %s%s (relint)" file
                           (elisp-agent--line (aref diag 1)) (aref diag 0)
                           (if (aref diag 4) (format ": %S" (aref diag 4)) ""))))))

(defun elisp-agent-check (args)
  "Check the files in ARGS."
  (let ((doc (member "--doc" args))
        (regexp (member "--regexp" args))
        (allow-warnings (member "--allow-warnings" args)))
    (dolist (file (cl-remove-if (lambda (a) (string-prefix-p "--" a)) args))
      ;; Compiling a file with broken structure only adds noise.
      (when (elisp-agent--check-structure file)
        (elisp-agent--byte-compile file allow-warnings)
        (when doc (elisp-agent--checkdoc file))
        (when regexp (elisp-agent--relint file))))))

;;;; forms

(defun elisp-agent-forms (args)
  "List the top-level forms of the file in ARGS with their line ranges."
  (let ((file (car args)))
    (with-temp-buffer
      (insert-file-contents file)
      (emacs-lisp-mode)
      (goto-char (point-min))
      (condition-case nil
          (while (progn (forward-comment (buffer-size)) (not (eobp)))
            (let ((start (point)))
              (forward-sexp 1)
              (elisp-agent--say "%d-%d: %s" (elisp-agent--line start)
                                (elisp-agent--line (point))
                                (elisp-agent--form-name start))))
        (scan-error
         (elisp-agent--fail "%s: stops here, the structure is broken; run `elisp-agent check'"
                            file))))))

;;;; indent

(defun elisp-agent-indent (args)
  "Report lines of the files in ARGS that Emacs would indent differently.
With \"--fix\" in ARGS, rewrite the files with Emacs's indentation instead.
A misplaced paren changes the indentation of the lines after it, so
the first reported line is usually just after the mistake."
  (let ((fix (member "--fix" args)))
    (dolist (file (remove "--fix" args))
      (elisp-agent--indent-file file fix))))

(defun elisp-agent--indent-file (file fix)
  "Report up to 10 lines of FILE that Emacs would indent differently.
With FIX, write FILE back indented instead."
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (setq indent-tabs-mode nil)         ; count columns, and never write tabs
    ;; Macros only indent correctly once they are defined: load the
    ;; required libraries and evaluate the file's own macros.
    (let ((load-path (cons (file-name-directory (expand-file-name file)) load-path)))
      (goto-char (point-min))
      (while (re-search-forward "^(require '\\([^ )]+\\)" nil t)
        (ignore-errors (require (intern (match-string 1)))))
      (goto-char (point-min))
      (while (re-search-forward "^(defmacro " nil t)
        (goto-char (match-beginning 0))
        (ignore-errors (eval (read (current-buffer)) t))))
    (let ((before (split-string (buffer-string) "\n"))
          (shown 0))
      (let ((inhibit-message t))
        (indent-region (point-min) (point-max)))
      (if fix
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region nil nil file nil 'silent))
        (cl-loop for old in before
                 for new in (split-string (buffer-string) "\n")
                 for line from 1
                 unless (or (equal old new) (>= shown 10))
                 do (cl-incf shown)
                 (elisp-agent--fail "%s:%d: indentation %d, expected %d: %s"
                                    file line
                                    (- (length old) (length (string-trim-left old)))
                                    (- (length new) (length (string-trim-left new)))
                                    (string-trim old)))))))

;;;; describe

(defun elisp-agent--first-line (doc)
  "Return the first line of docstring DOC."
  (if doc (car (split-string doc "\n")) "(no documentation)"))

(defun elisp-agent--similar (name)
  "Defined symbols whose names are close to NAME.
That is, names a few edits away, and defined tails of NAME: for
\"string-length\" that finds \"length\"."
  (let ((parts (split-string name "-"))
        found)
    (while (cdr parts)
      (setq parts (cdr parts))
      (let ((tail (intern-soft (string-join parts "-"))))
        (when (and tail (fboundp tail)) (push (symbol-name tail) found))))
    (mapatoms (lambda (s)
                (when (and (or (fboundp s) (boundp s))
                           (let ((n (symbol-name s)))
                             (and (< (abs (- (length n) (length name))) 4)
                                  (<= (string-distance n name) 2))))
                  (push (symbol-name s) found))))
    (sort (delete-dups found) #'string<)))

(defun elisp-agent-describe (args)
  "Describe the symbols in ARGS."
  (dolist (name args)
    (let ((sym (intern-soft name)))
      (cond
       ((and sym (fboundp sym))
        (let ((def (symbol-function sym)))
          (when (autoloadp def)
            (ignore-errors (autoload-do-load def sym)))
          (elisp-agent--say "%s: %s %S" name
                            (cond ((special-form-p sym) "special form")
                                  ((macrop sym) "macro")
                                  ((commandp sym) "command")
                                  (t "function"))
                            (help-function-arglist sym t))
          (elisp-agent--say "  %s" (elisp-agent--first-line
                                    (ignore-errors (documentation sym t))))
          (when-let* ((file (symbol-file sym 'defun)))
            (elisp-agent--say "  defined in %s" file))
          (when-let* ((obsolete (get sym 'byte-obsolete-info)))
            (elisp-agent--say "  OBSOLETE, use %s instead" (car obsolete)))))
       ((and sym (boundp sym))
        (elisp-agent--say "%s: variable, value %S" name (symbol-value sym))
        (elisp-agent--say "  %s" (elisp-agent--first-line
                                  (documentation-property
                                   sym 'variable-documentation t))))
       (t
        (elisp-agent--fail "%s: NOT DEFINED (load or require its library first?)%s" name
                           (if-let* ((similar (elisp-agent--similar name)))
                               (format "  Similar: %s" (string-join similar " "))
                             "")))))))

;;;; builtins

(defun elisp-agent-builtins (args)
  "List shortdoc groups, or the functions of the group in ARGS."
  (require 'shortdoc)
  (if (null args)
      (elisp-agent--say "Groups: %s\nUse: elisp-agent builtins GROUP"
                        (mapconcat (lambda (g) (symbol-name (car g))) shortdoc--groups " "))
    (dolist (item (cdr (assq (intern (car args)) shortdoc--groups)))
      (cond ((stringp item) (elisp-agent--say "\n;; %s" item))
            ((and (consp item) (symbolp (car item)) (fboundp (car item)))
             (elisp-agent--say "%-32s %s" (car item)
                               (elisp-agent--first-line
                                (ignore-errors (documentation (car item) t)))))))))

;;;; info

(defun elisp-agent--info-manuals ()
  "Return the names of the installed Info manuals, sorted."
  (let (names)
    (dolist (dir Info-directory-list)
      (dolist (file (and (file-directory-p dir)
                         (directory-files dir nil "\\.info\\(?:-[0-9]+\\)?\\(?:\\.[a-z0-9]+\\)?\\'")))
        (push (replace-regexp-in-string "\\.info.*\\'" "" file) names)))
    (sort (delete-dups names) #'string<)))

(defun elisp-agent--info-url (manual node)
  "Return the gnu.org address of NODE in Emacs's MANUAL.
Texinfo writes spaces as dashes and other characters as _00XX."
  (format "https://www.gnu.org/software/emacs/manual/html_node/%s/%s.html"
          manual
          (if (equal node "Top")
              "index"
            (mapconcat (lambda (c)
                         (cond ((eq c ?\s) "-")
                               ((string-match-p "[[:alnum:]]" (string c)) (string c))
                               (t (format "_%04x" c))))
                       node ""))))

(defun elisp-agent--info-visit (manual node)
  "Go to NODE of MANUAL in the Info buffer; return nil if MANUAL is missing."
  (condition-case nil
      (progn (Info-find-node manual node) t)
    (user-error
     (elisp-agent--fail "Manual %s is not installed. Installed: %s\n  Online, if it is an Emacs manual: %s\n  (On Debian and Ubuntu the Emacs manuals are in the package emacs-common-non-dfsg.)"
                        manual (string-join (elisp-agent--info-manuals) " ")
                        (elisp-agent--info-url manual node))
     nil)))

(defun elisp-agent--info-index (manual topic)
  "List the index entries of MANUAL that contain TOPIC."
  (when (elisp-agent--info-visit manual "Top")
    (condition-case nil
        (progn
          (Info-index topic)
          (dolist (entry Info-index-alternatives)
            (elisp-agent--say "%s: (%s) %s, line %s"
                              (substring-no-properties (car entry))
                              manual (nth 1 entry) (nth 3 entry))))
      (user-error (elisp-agent--fail "%s: not in the index of %s; try --search" topic manual)))))

(defun elisp-agent--info-search (manual regexp)
  "List the nodes of MANUAL with text matching REGEXP, and the matching lines."
  (when (elisp-agent--info-visit manual "Top")
    (let ((found 0))
      (condition-case nil
          (while (< found 50)
            (Info-search regexp)
            (setq found (1+ found))
            (elisp-agent--say "(%s) %s: %s" manual Info-current-node
                              (string-trim (buffer-substring-no-properties
                                            (line-beginning-position) (line-end-position))))
            (forward-line 1))
        ((user-error search-failed) nil))
      (when (zerop found)
        (elisp-agent--fail "%s: not found in %s" regexp manual)))))

(defun elisp-agent-info (args)
  "Read Info manuals as ARGS say.
No ARGS: list the installed manuals.  MANUAL [NODE]: print a node
\(default Top); \"(MANUAL) NODE\" works too.  --index MANUAL TOPIC: index
entries.  --search MANUAL REGEXP: nodes with matching text."
  (info-initialize)
  ;; "(elisp) Node" as written in cross references: split it.
  (when (and (= (length args) 1)
             (string-match "\\`(\\([^)]+\\)) *\\(.*\\)\\'" (car args)))
    (setq args (list (match-string 1 (car args)) (match-string 2 (car args)))))
  (let ((inhibit-message t))            ; Info reports every step
    (pcase args
      ('nil (elisp-agent--say "%s" (string-join (elisp-agent--info-manuals) " ")))
      (`("--index" ,manual ,topic) (elisp-agent--info-index manual topic))
      (`("--search" ,manual ,regexp) (elisp-agent--info-search manual regexp))
      ((and `(,manual . ,node) (guard (not (string-prefix-p "-" manual))) (guard (null (cdr node))))
       (when (elisp-agent--info-visit manual (if (member (car node) '(nil "")) "Top" (car node)))
         (elisp-agent--say "%s" (buffer-substring-no-properties (point-min) (point-max)))))
      (_ (elisp-agent--fail "Usage: elisp-agent info [MANUAL [NODE] | --index MANUAL TOPIC | --search MANUAL REGEXP]")))))

;;;; eval

(defun elisp-agent-eval (args)
  "Evaluate the expressions in ARGS and print each result."
  (let ((pos 0)
        (text (string-join args " ")))
    (condition-case err
        (while (string-match-p "[^ \t\n]" (substring text pos))
          (pcase-let ((`(,form . ,end) (read-from-string text pos)))
            (setq pos end)
            (elisp-agent--say "%S" (eval form t))))
      (error (elisp-agent--fail "ERROR: %S" err)))))

;;;; test

(defun elisp-agent-test (args)
  "Run ERT on the test files in ARGS, limited by \"-s SELECTOR\" if given."
  (let ((selector t) files)
    (while args
      (let ((arg (pop args)))
        (if (equal arg "-s")
            (setq selector (pop args))
          (push arg files))))
    (dolist (file (nreverse files))
      (load (expand-file-name file) nil t))
    (ert-run-tests-batch-and-exit selector)))

;;;; Main

(defun elisp-agent-main ()
  "Entry point for the `elisp-agent' script."
  (let* ((args (elisp-agent--parse-options command-line-args-left))
         (command (pop args)))
    (setq command-line-args-left nil)
    (pcase command
      ("check" (elisp-agent-check args))
      ("forms" (elisp-agent-forms args))
      ("indent" (elisp-agent-indent args))
      ("describe" (elisp-agent-describe args))
      ("builtins" (elisp-agent-builtins args))
      ("info" (elisp-agent-info args))
      ("eval" (elisp-agent-eval args))
      ("test" (elisp-agent-test args))
      (_ (elisp-agent--fail "Usage: elisp-agent check|forms|indent|describe|builtins|info|eval|test ...")))
    (kill-emacs (if elisp-agent--failed 1 0))))

(provide 'elisp-agent)
;;; elisp-agent.el ends here
