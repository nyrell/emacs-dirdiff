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
;; Options go before the command; for `eval' they must.
;;
;; Output is one finding per line, as FILE:LINE: MESSAGE where possible.
;; The exit status is 0 when everything is fine and 1 otherwise.
;;
;; Compiling, describing, evaluating and testing run in a fresh
;; `emacs --batch -Q' (see elisp-agent-child.el), because this Emacs has
;; loaded libraries such as cl-lib that would hide a missing `require'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
;; Load libraries before let-binding their variables; otherwise the
;; binding is lexical and has no effect (or is an error).
(require 'bytecomp)
(require 'checkdoc)
(require 'warnings)                     ; before mocking display-warning
(require 'info)
(require 'check-declare)

(defvar elisp-agent--failed nil "Non-nil once a check has failed.")

(defconst elisp-agent--child-file
  (expand-file-name "elisp-agent-child.el"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The file loaded into the clean Emacs that compiles, describes and tests.")

(defvar elisp-agent--child-args nil
  "Command-line arguments that give the clean Emacs the same options.")

(defun elisp-agent--say (format-string &rest args)
  "Print FORMAT-STRING with ARGS on a line of its own to standard output."
  (princ (concat (apply #'format format-string args) "\n")))

(defun elisp-agent--fail (format-string &rest args)
  "Print FORMAT-STRING with ARGS as a finding and remember the failure."
  (setq elisp-agent--failed t)
  (apply #'elisp-agent--say format-string args))

;;;; Options

(defun elisp-agent--option-value (option args)
  "Return the value of OPTION, the first of ARGS, or signal an error."
  (or (car args) (user-error "Option %s needs a value" option)))

(defun elisp-agent--parse-options (args)
  "Handle the common options in ARGS; return the remaining arguments.
Also record them in `elisp-agent--child-args' for the clean Emacs."
  (let (rest)
    (while args
      (let ((arg (pop args)))
        (pcase arg
          ("-L" (let ((dir (expand-file-name (elisp-agent--option-value arg args))))
                  (pop args)
                  (push dir load-path)
                  (setq elisp-agent--child-args
                        (append elisp-agent--child-args (list "-L" dir)))))
          ("-l" (let ((file (expand-file-name (elisp-agent--option-value arg args))))
                  (pop args)
                  (load file nil t)
                  (setq elisp-agent--child-args
                        (append elisp-agent--child-args (list "-l" file)))))
          ("--require" (let ((feature (intern (elisp-agent--option-value arg args))))
                         (pop args)
                         (require feature)
                         (setq elisp-agent--child-args
                               (append elisp-agent--child-args
                                       (list "--eval" (format "(require '%S)" feature))))))
          ("--packages"
           (let ((dir (getenv "ELISP_AGENT_PACKAGE_DIR"))
                 (init "(progn (require 'package) %s (package-initialize))"))
             (require 'package)
             (when dir (setq package-user-dir dir))
             (package-initialize)
             (setq elisp-agent--child-args
                   (append elisp-agent--child-args
                           (list "--eval"
                                 (format init (if dir (format "(setq package-user-dir %S)" dir) "")))))))
          (_ (push arg rest)))))
    (nreverse rest)))

(defun elisp-agent--child (&rest args)
  "Run a clean `emacs --batch -Q' with the common options and ARGS.
It loads `elisp-agent--child-file' first.  Print its output and
remember a failure if it exits with a non-zero status."
  (with-temp-buffer
    (let ((status (apply #'call-process
                         (expand-file-name invocation-name invocation-directory)
                         nil t nil "--batch" "-Q" "-l" elisp-agent--child-file
                         (append elisp-agent--child-args args))))
      (princ (buffer-string))
      (unless (or (bobp) (= (char-before (point-max)) ?\n))
        (terpri))
      (unless (eq status 0)
        (setq elisp-agent--failed t))
      status)))

(defun elisp-agent--existing-files (files)
  "Return those of FILES that exist; report the others as failures."
  (seq-filter (lambda (file)
                (or (file-readable-p file)
                    (progn (elisp-agent--fail "%s: no such file" file) nil)))
              files))

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

(defun elisp-agent--readable-p ()
  "Return non-nil if the Lisp reader can read the whole current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((last (point)))
      (condition-case nil
          (while t
            (read (current-buffer))
            (setq last (point)))
        (end-of-file
         ;; Also signaled for a form that is not closed: then text is left.
         (goto-char last)
         (forward-comment (buffer-size))
         (eobp))
        (error nil)))))

(defun elisp-agent--check-structure (file)
  "Report unbalanced parentheses in FILE, in words.  Return non-nil if OK."
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (let ((problems nil))
      (cl-letf (((symbol-function 'elisp-agent--fail)
                 (lambda (&rest args) (push args problems))))
        (elisp-agent--scan-structure file))
      (cond
       ((null problems) t)
       ;; The reader is happy, but the paren scanner is not: character
       ;; literals like ?( fool the scanner (and editors and indentation).
       ((elisp-agent--readable-p)
        (elisp-agent--fail "%s:%s: unescaped character literal(s) like ?( ?) ?; ?\" confuse Emacs's paren scanner, indentation and this tool; write ?\\( ?\\) ?\\; ?\\\" instead"
                           file
                           (let (lines)
                             (goto-char (point-min))
                             (while (re-search-forward "\\(?:^\\|[^\\]\\)\\?[][();\"]" nil t)
                               ;; `syntax-ppss' moves point.
                               (let ((ppss (save-excursion (syntax-ppss (1- (point))))))
                                 (unless (or (nth 3 ppss) (nth 4 ppss))
                                   (push (elisp-agent--line (point)) lines))))
                             (mapconcat #'number-to-string (delete-dups (nreverse lines)) ",")))
        nil)
       (t
        (dolist (problem (nreverse problems))
          (apply #'elisp-agent--fail problem))
        nil)))))

(defun elisp-agent--scan-structure (file)
  "Report the paren problems of FILE, which is in the current buffer."
  (let ((ok t)
        (reported nil))
    ;; A definition at column 0 that is nested inside another form
    ;; almost always means the form before it lacks closing parens.
    ;; Report the first one for each unclosed form.
    (goto-char (point-min))
    (while (re-search-forward "^(" nil t)
      (let* ((pos (match-beginning 0))
             ;; `syntax-ppss' moves point to POS.
             (ppss (save-excursion (syntax-ppss pos))))
        (when (and (> (nth 0 ppss) 0) (not (nth 3 ppss)) (not (nth 4 ppss))
                   (not (memq (car (nth 9 ppss)) reported)))
          (let ((outer (car (nth 9 ppss))))
            (push outer reported)
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
    ok))

(defun elisp-agent--byte-compile (file allow-warnings)
  "Byte-compile FILE in a clean Emacs, printing warnings.
Warnings count as failures unless ALLOW-WARNINGS."
  (elisp-agent--child "--eval" (format "(elisp-agent-child-compile %S %S)"
                                       (expand-file-name file) (and allow-warnings t))))

(defun elisp-agent--checkdoc (file)
  "Run checkdoc on FILE and report its findings."
  ;; In batch mode checkdoc reports through `display-warning'.
  (let (findings)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &rest _) (push message findings))))
      (checkdoc-file file))
    (dolist (finding (nreverse findings))
      (elisp-agent--fail "%s (checkdoc)" (string-trim finding)))))

(defun elisp-agent--check-declare (file)
  "Report `declare-function' forms in FILE that name a wrong file or arglist."
  (let ((inhibit-message t))
    (cl-letf (((symbol-function 'display-warning) #'ignore))
      (dolist (entry (check-declare-file file))
        (dolist (problem (cdr entry))
          ;; PROBLEM is (FILE FUNCTION MESSAGE).
          (elisp-agent--fail "%s:%d: declare-function %s: %s in %s%s (check-declare)"
                             file
                             (with-temp-buffer
                               (insert-file-contents file)
                               (if (re-search-forward
                                    (concat "(declare-function +" (regexp-quote (nth 1 problem)) "\\_>")
                                    nil t)
                                   (elisp-agent--line (point))
                                 1))
                             (nth 1 problem) (nth 2 problem)
                             (file-name-nondirectory (car entry))
                             (if (equal (nth 2 problem) "file not found")
                                 "; for a package that is not part of Emacs, write \"ext:FILE\""
                               "")))))))

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
        (allow-warnings (member "--allow-warnings" args))
        (files (seq-remove (lambda (a) (string-prefix-p "--" a)) args)))
    (unless files
      (elisp-agent--fail "Usage: elisp-agent check [--doc] [--regexp] [--allow-warnings] FILE..."))
    (dolist (file (elisp-agent--existing-files files))
      ;; Compiling a file with broken structure only adds noise.
      (when (elisp-agent--check-structure file)
        (elisp-agent--byte-compile file allow-warnings)
        (elisp-agent--check-declare file)
        (when doc (elisp-agent--checkdoc file))
        (when regexp (elisp-agent--relint file))))))

;;;; forms

(defun elisp-agent-forms (args)
  "List the top-level forms of the file in ARGS with their line ranges."
  (let ((file (car args)))
    (cond
     ((null file) (elisp-agent--fail "Usage: elisp-agent forms FILE"))
     ((elisp-agent--existing-files (list file))
      (elisp-agent--forms file)))))

(defun elisp-agent--forms (file)
  "List the top-level forms of FILE with their line ranges."
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
                          file)))))

;;;; indent

(defun elisp-agent-indent (args)
  "Report lines of the files in ARGS that Emacs would indent differently.
With \"--fix\" in ARGS, rewrite the files with Emacs's indentation instead.
A misplaced paren changes the indentation of the lines after it, so
the first reported line is usually just after the mistake."
  (let ((fix (member "--fix" args))
        (files (remove "--fix" args)))
    (unless files
      (elisp-agent--fail "Usage: elisp-agent indent [--fix] FILE..."))
    (dolist (file (elisp-agent--existing-files files))
      (if (and fix (not (elisp-agent--check-structure file)))
          ;; Re-indenting would move the code to match the wrong parens
          ;; and erase the indentation that shows where they belong.
          (elisp-agent--fail "%s: not re-indented; fix the parens first (see above)" file)
        (elisp-agent--indent-file file fix)))))

(defun elisp-agent--indent-file (file fix)
  "Report up to 10 lines of FILE that Emacs would indent differently.
With FIX, write FILE back indented instead."
  (with-temp-buffer
    (insert-file-contents file)
    (setq buffer-file-coding-system last-coding-system-used) ; write it back the same way
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
          (let ((changed (cl-count-if-not #'identity
                                          (cl-mapcar #'equal before
                                                     (split-string (buffer-string) "\n")))))
            (if (zerop changed)
                (elisp-agent--say "%s: already indented" file)
              (let ((coding-system-for-write buffer-file-coding-system))
                (write-region nil nil file nil 'silent))
              (elisp-agent--say "%s: re-indented %d line(s)" file changed)))
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

(defun elisp-agent-describe (args)
  "Describe the symbols in ARGS, each as a fresh clean Emacs sees it."
  (unless args
    (elisp-agent--fail "Usage: elisp-agent describe SYMBOL..."))
  (dolist (name args)
    (elisp-agent--child "--eval" (format "(elisp-agent-child-describe %S)" name))))

;;;; builtins

(defun elisp-agent-builtins (args)
  "List shortdoc groups, or the functions of the group in ARGS."
  (elisp-agent--child "--eval" (format "(elisp-agent-child-builtins %S)" (car args))))

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
  "Go to NODE of MANUAL in the Info buffer; return nil if that fails."
  (if (Info-find-file manual t)
      (condition-case nil
          (progn (Info-find-node manual node) t)
        (user-error
         (elisp-agent--fail "%s: no node \"%s\". List the nodes with: elisp-agent info %s; or search: elisp-agent info --index %s TOPIC"
                            manual node manual manual)
         nil))
    (elisp-agent--fail "Manual %s is not installed. Installed: %s\n  Online, if it is an Emacs manual: %s\n  (On Debian and Ubuntu the Emacs manuals are in the package emacs-common-non-dfsg.)"
                       manual (string-join (elisp-agent--info-manuals) " ")
                       (elisp-agent--info-url manual node))
    nil))

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
  "Evaluate the expressions in ARGS in a clean Emacs and print each result."
  (if (null args)
      (elisp-agent--fail "Usage: elisp-agent eval EXPRESSION...")
    (elisp-agent--child "--eval" (format "(elisp-agent-child-eval %S)" (string-join args " ")))))

;;;; test

(defun elisp-agent-test (args)
  "Run ERT in a clean Emacs on the test files in ARGS.
\"-s SELECTOR\" in ARGS runs only the tests whose names match it."
  (let ((selector t) files)
    (while args
      (let ((arg (pop args)))
        (if (equal arg "-s")
            (setq selector (or (pop args) (user-error "Option -s needs a regexp")))
          (push arg files))))
    (setq files (nreverse files))
    (cond
     ((null files) (elisp-agent--fail "Usage: elisp-agent test FILE... [-s SELECTOR]"))
     ((setq files (elisp-agent--existing-files files))
      (apply #'elisp-agent--child
             (append '("-l" "ert")
                     (mapcan (lambda (f) (list "-l" (expand-file-name f))) files)
                     (list "--eval" (format "(elisp-agent-child-test %S)" selector))))))))

;;;; Main

(defun elisp-agent-main ()
  "Entry point for the `elisp-agent' script."
  (let ((args command-line-args-left))
    (setq command-line-args-left nil)
    (condition-case err
        (elisp-agent--run args)
      (error (elisp-agent--fail "elisp-agent: %s" (error-message-string err))))
    (kill-emacs (if elisp-agent--failed 1 0))))

(defun elisp-agent--run (args)
  "Run the command in ARGS, after the options before it."
  (let ((before nil))
    ;; Options before the command; for all but eval, also after it.
    (while (and args (string-prefix-p "-" (car args)))
      (push (pop args) before)
      (when (member (car before) '("-L" "-l" "--require"))
        (push (pop args) before)))
    (elisp-agent--parse-options (nreverse before))
    (let ((command (pop args)))
      (unless (equal command "eval")
        (setq args (elisp-agent--parse-options args)))
      (pcase command
        ("check" (elisp-agent-check args))
        ("forms" (elisp-agent-forms args))
        ("indent" (elisp-agent-indent args))
        ("describe" (elisp-agent-describe args))
        ("builtins" (elisp-agent-builtins args))
        ("info" (elisp-agent-info args))
        ("eval" (elisp-agent-eval args))
        ("test" (elisp-agent-test args))
        (_ (elisp-agent--fail "Usage: elisp-agent [OPTIONS] check|forms|indent|describe|builtins|info|eval|test ..."))))))

(provide 'elisp-agent)
;;; elisp-agent.el ends here
