;;; dirdiff-test.el --- Tests for dirdiff  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run the tests with:
;; `emacs --batch -Q -L . -l test/dirdiff-test.el -f ert-run-tests-batch-and-exit'

;;; Code:

(require 'ert)
(require 'dirdiff)
(require 'dirdiff-git)

;;;; Helpers

(defun dirdiff-test--write (root spec)
  "Create files under ROOT from SPEC, a list of (PATH . CONTENT).
CONTENT is a string, `dir' for an empty directory or (link . TARGET)."
  (pcase-dolist (`(,path . ,content) spec)
    (let ((file (expand-file-name path root)))
      (make-directory (file-name-directory file) t)
      (pcase content
        ('dir (make-directory file t))
        (`(link . ,target) (make-symbolic-link target file))
        (_ (let ((coding-system-for-write 'no-conversion))
             (write-region content nil file nil 'silent)))))))

(defmacro dirdiff-test--with-dirs (left-spec right-spec &rest body)
  "Run BODY with `left' and `right' bound to new directories.
They are filled from LEFT-SPEC and RIGHT-SPEC, see `dirdiff-test--write'."
  (declare (indent 2))
  `(let* ((root (make-temp-file "dirdiff-test-" t))
          (left (expand-file-name "left/" root))
          (right (expand-file-name "right/" root)))
     (unwind-protect
         (progn
           (make-directory left t)
           (make-directory right t)
           (dirdiff-test--write left ,left-spec)
           (dirdiff-test--write right ,right-spec)
           ,@body)
       (delete-directory root t))))

(defun dirdiff-test--session (left right &rest options)
  "Return a compared session of directories LEFT and RIGHT with OPTIONS."
  (let ((session (apply #'dirdiff-session-create
                        :left (dirdiff-dir-source-create :root left :label "L" :writable t)
                        :right (dirdiff-dir-source-create :root right :label "R" :writable t)
                        options)))
    (dirdiff--build-tree session)
    session))

(defun dirdiff-test--find (session rel)
  "Return the node of SESSION at relative name REL, or nil."
  (catch 'found
    (dirdiff--walk (dirdiff-session-tree session)
                   (lambda (n) (when (equal (dirdiff-node-rel n) rel) (throw 'found n))))
    nil))

(defun dirdiff-test--status (session rel)
  "Return the status of the node of SESSION at REL."
  (dirdiff-node-status (or (dirdiff-test--find session rel) (error "No node %s" rel))))

(defun dirdiff-test--statuses (session)
  "Return an alist (REL . STATUS) of all nodes of SESSION, in display order."
  (let (result)
    (dirdiff--walk (dirdiff-session-tree session)
                   (lambda (n) (push (cons (dirdiff-node-rel n) (dirdiff-node-status n)) result)))
    (nreverse result)))

(defmacro dirdiff-test--in-buffer (session &rest body)
  "Run BODY in a dirdiff buffer showing SESSION; say yes to every question."
  (declare (indent 1))
  `(let ((buffer (dirdiff-show-session ,session)))
     (unwind-protect
         (with-current-buffer buffer
           (cl-letf (((symbol-function 'y-or-n-p) #'always)
                     ((symbol-function 'yes-or-no-p) #'always))
             ,@body))
       (kill-buffer buffer))))

(defun dirdiff-test--lines ()
  "Return the lines of the buffer, with consecutive spaces collapsed."
  (mapcar (lambda (l) (string-trim (replace-regexp-in-string " +" " " l)))
          (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n" t)))

(defun dirdiff-test--read (file)
  "Return the contents of FILE."
  (with-temp-buffer (insert-file-contents-literally file) (buffer-string)))

;;;; Comparison engine

(ert-deftest dirdiff-test-statuses ()
  (dirdiff-test--with-dirs
      '(("same.txt" . "a\n") ("changed.txt" . "a\n") ("left.txt" . "x")
        ("dir/same.txt" . "s") ("dir/sub/changed.c" . "1")
        ("leftdir/a" . "a") ("leftdir/b/c" . "c")
        ("conflict" . "file") ("samedir/x" . "x") ("empty" . ""))
      '(("same.txt" . "a\n") ("changed.txt" . "b\n") ("right.txt" . "y")
        ("dir/same.txt" . "s") ("dir/sub/changed.c" . "2")
        ("conflict/inner" . "i") ("samedir/x" . "x") ("empty" . ""))
    (let ((s (dirdiff-test--session left right)))
      (should (equal (dirdiff-test--statuses s)
                     '(("conflict" . conflict) ("conflict/inner" . right)
                       ("dir" . changed) ("dir/sub" . changed) ("dir/sub/changed.c" . changed)
                       ("dir/same.txt" . same)
                       ("leftdir" . left) ("leftdir/b" . left) ("leftdir/b/c" . left)
                       ("leftdir/a" . left)
                       ("samedir" . same) ("samedir/x" . same)
                       ("changed.txt" . changed) ("empty" . same) ("left.txt" . left)
                       ("right.txt" . right) ("same.txt" . same))))
      (should (eq (dirdiff-node-status (dirdiff-session-tree s)) 'changed)))))

(ert-deftest dirdiff-test-identical-trees ()
  (dirdiff-test--with-dirs '(("a/b" . "x")) '(("a/b" . "x"))
    (should (eq (dirdiff-node-status (dirdiff-session-tree (dirdiff-test--session left right)))
                'same))))

(ert-deftest dirdiff-test-ignore-whitespace ()
  (dirdiff-test--with-dirs
      '(("ws.txt" . "int  x = 1;\n") ("real.txt" . "a b\n") ("lines.txt" . "a\nb\n"))
      '(("ws.txt" . "int x=1;\r\n") ("real.txt" . "a c\n") ("lines.txt" . "a\n\nb\n"))
    (let ((s (dirdiff-test--session left right)))
      (should (eq (dirdiff-test--status s "ws.txt") 'changed)))
    (let ((s (dirdiff-test--session left right :ignore-whitespace t)))
      (should (eq (dirdiff-test--status s "ws.txt") 'same))
      (should (eq (dirdiff-test--status s "real.txt") 'changed))
      ;; Like `diff -w', blank lines still count.
      (should (eq (dirdiff-test--status s "lines.txt") 'changed)))))

(ert-deftest dirdiff-test-ignore-whitespace-large-files ()
  (dirdiff-test--with-dirs '(("big" . "a  b\n")) '(("big" . "a b\n"))
    (let ((dirdiff--large-file-size 1))
      (should (eq (dirdiff-test--status
                   (dirdiff-test--session left right :ignore-whitespace t) "big")
                  'same))
      (should (eq (dirdiff-test--status (dirdiff-test--session left right) "big")
                  'changed)))))

(ert-deftest dirdiff-test-binary-files ()
  (dirdiff-test--with-dirs
      '(("same-size.bin" . "\0abc") ("other-size.bin" . "\0ab") ("identical.bin" . "\0x"))
      '(("same-size.bin" . "\0abd") ("other-size.bin" . "\0abc") ("identical.bin" . "\0x"))
    (let ((time (encode-time '(0 0 12 1 1 2020 nil nil t))))
      (dolist (f '("same-size.bin" "identical.bin"))
        (set-file-times (expand-file-name f left) time)
        (set-file-times (expand-file-name f right) time)))
    ;; Quick: same size and time counts as identical, even if the
    ;; contents differ.
    (let ((s (dirdiff-test--session left right :binary-comparison 'quick)))
      (should (eq (dirdiff-test--status s "same-size.bin") 'same))
      (should (eq (dirdiff-test--status s "other-size.bin") 'changed)))
    (let ((s (dirdiff-test--session left right :binary-comparison 'full)))
      (should (eq (dirdiff-test--status s "same-size.bin") 'changed))
      (should (eq (dirdiff-test--status s "identical.bin") 'same)))
    ;; Different times: quick compares the contents.
    (set-file-times (expand-file-name "identical.bin" right) (current-time))
    (set-file-times (expand-file-name "same-size.bin" right) (current-time))
    (let ((s (dirdiff-test--session left right :binary-comparison 'quick)))
      (should (eq (dirdiff-test--status s "identical.bin") 'same))
      (should (eq (dirdiff-test--status s "same-size.bin") 'changed)))))

(ert-deftest dirdiff-test-ignored-names ()
  (dirdiff-test--with-dirs '((".git/HEAD" . "a") ("CVS/x" . "x") ("f" . "f"))
      '((".git/HEAD" . "b") ("f" . "f"))
    (should (equal (dirdiff-test--statuses (dirdiff-test--session left right))
                   '(("f" . same))))
    (let ((dirdiff-ignored-names nil))
      (should (equal (mapcar #'car (dirdiff-test--statuses (dirdiff-test--session left right)))
                     '(".git" ".git/HEAD" "CVS" "CVS/x" "f"))))))

(ert-deftest dirdiff-test-symlinks ()
  (dirdiff-test--with-dirs
      '(("real" . "content") ("link-to-file" link . "real") ("dir/x" . "x")
        ("link-to-dir" link . "dir") ("broken" link . "nowhere"))
      '(("real" . "content") ("link-to-file" . "content") ("dir/x" . "x")
        ("link-to-dir" link . "dir") ("broken" link . "elsewhere"))
    (let ((s (dirdiff-test--session left right)))
      ;; A link to a file is compared by the contents of its target.
      (should (eq (dirdiff-test--status s "link-to-file") 'same))
      ;; Links to directories are not followed: compared by target.
      (should (eq (dirdiff-entry-type (dirdiff-node-left (dirdiff-test--find s "link-to-dir")))
                  'link))
      (should (eq (dirdiff-test--status s "link-to-dir") 'same))
      (should (eq (dirdiff-test--status s "broken") 'changed)))))

(ert-deftest dirdiff-test-difference-navigation-order ()
  (dirdiff-test--with-dirs
      '(("a/x" . "1") ("a/y" . "y") ("only/deep/z" . "z") ("b" . "b"))
      '(("a/x" . "2") ("a/y" . "y") ("b" . "B"))
    (let ((s (dirdiff-test--session left right))
          diffs)
      (dirdiff--walk (dirdiff-session-tree s)
                     (lambda (n) (when (dirdiff--difference-p n) (push (dirdiff-node-rel n) diffs))))
      ;; One-sided directories count once, changed directories not at all.
      (should (equal (nreverse diffs) '("a/x" "only" "b"))))))

;;;; View

(ert-deftest dirdiff-test-view-rows-and-expansion ()
  (dirdiff-test--with-dirs
      '(("changed/f" . "1") ("same/f" . "s") ("top" . "t"))
      '(("changed/f" . "2") ("same/f" . "s") ("top" . "t"))
    (let ((dirdiff-initial-expansion 'changed))
      (dirdiff-test--in-buffer (dirdiff-test--session left right)
        (should (equal (dirdiff-test--lines)
                       '("▾ changed/ | ▾ changed/" "f | f"
                         "▸ same/ ▸ same/" "top top")))
        (dirdiff-collapse-all)
        (should (equal (length (dirdiff-test--lines)) 3))
        (dirdiff-expand-all)
        (should (equal (length (dirdiff-test--lines)) 5))
        (dirdiff-toggle-hide-identical)
        (should (equal (dirdiff-test--lines)
                       '("▾ changed/ | ▾ changed/" "f | f")))))))

(ert-deftest dirdiff-test-view-sides-and-navigation ()
  (dirdiff-test--with-dirs
      '(("a/b/x" . "1") ("a/same" . "s") ("left-only" . "l"))
      '(("a/b/x" . "2") ("a/same" . "s"))
    (let ((dirdiff-initial-expansion 'none))
      (dirdiff-test--in-buffer (dirdiff-test--session left right)
        (should (eq dirdiff--side 'left))
        (should (= (current-column) 0))
        (dirdiff-switch-side)
        (should (eq dirdiff--side 'right))
        (should (= (current-column) (+ dirdiff--width 3)))
        ;; Point stays on the right side when moving down.
        (forward-line 1)
        (dirdiff--post-command)
        (should (eq dirdiff--side 'right))
        ;; Next difference expands a/ and a/b/.
        (goto-char (point-min))
        (dirdiff-next-difference)
        (should (equal (dirdiff-node-rel (dirdiff--current-node)) "a/b/x"))
        (dirdiff-next-difference)
        (should (equal (dirdiff-node-rel (dirdiff--current-node)) "left-only"))
        (dirdiff-previous-difference)
        (should (equal (dirdiff-node-rel (dirdiff--current-node)) "a/b/x"))
        (dirdiff-up)
        (should (equal (dirdiff-node-rel (dirdiff--current-node)) "a/b"))
        ;; Collapsing keeps point on the nearest visible ancestor.
        (dirdiff-next-difference)
        (dirdiff-collapse-all)
        (should (equal (dirdiff-node-rel (dirdiff--current-node)) "a"))))))

(ert-deftest dirdiff-test-mode-line-counts ()
  (dirdiff-test--with-dirs '(("c" . "1") ("l" . "l")) '(("c" . "2") ("r" . "r") ("r2" . "r"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (should (string-prefix-p " |1 <1 >2" (dirdiff--mode-line))))))

;; Bug: the active side used to be derived from the cursor column after
;; every command, so moving to the start of the line switched sides.
(ert-deftest dirdiff-test-side-only-changes-on-request ()
  (dirdiff-test--with-dirs '(("a" . "1") ("b" . "2")) '(("a" . "x") ("b" . "y"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (dirdiff-switch-side)
      (should (eq dirdiff--side 'right))
      (dolist (move (list #'beginning-of-line #'beginning-of-buffer #'end-of-buffer))
        (funcall move)
        (dirdiff--post-command)
        (should (eq dirdiff--side 'right))))))

(ert-deftest dirdiff-test-wide-characters ()
  (dirdiff-test--with-dirs '(("日本語日本語.txt" . "1")) '(("日本語日本語.txt" . "2"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (dirdiff-switch-side)
      (should (eq (get-text-property (point) 'dirdiff-side) 'right))
      ;; The right cell starts after the left column and the gutter.
      (should (= (current-column) (+ dirdiff--width 3))))))

;;;; Editing

(defun dirdiff-test--goto (rel)
  "Move to the row of the node at REL, expanding directories as needed."
  (dirdiff--goto-node (dirdiff-test--find dirdiff--session rel)))

(ert-deftest dirdiff-test-keys ()
  (should (eq (keymap-lookup dirdiff-mode-map "M-<right>") #'dirdiff-copy-to-right))
  (should (eq (keymap-lookup dirdiff-mode-map "a") #'dirdiff-copy-to-right))
  (should (eq (keymap-lookup dirdiff-mode-map "M-<left>") #'dirdiff-copy-to-left))
  (should (eq (keymap-lookup dirdiff-mode-map "b") #'dirdiff-copy-to-left))
  (should (eq (keymap-lookup dirdiff-mode-map "!") #'dirdiff-refresh))
  (should (eq (keymap-lookup dirdiff-mode-map "M-<down>") #'dirdiff-next-difference))
  (should (eq (keymap-lookup dirdiff-mode-map "M-<up>") #'dirdiff-previous-difference))
  (should (eq (keymap-lookup dirdiff-mode-map "s") #'dirdiff-toggle-ignore-whitespace))
  (should (eq (keymap-lookup dirdiff-mode-map "w") #'dirdiff-copy-filename-as-kill))
  (should (eq (keymap-lookup dirdiff-mode-map "D") #'dirdiff-delete))
  (should (eq (keymap-lookup dirdiff-mode-map "C-x C-j") #'dirdiff-dired-jump)))

(ert-deftest dirdiff-test-dired-jump ()
  (dirdiff-test--with-dirs '(("d/f" . "1") ("l" . "l")) '(("d/f" . "2") ("d/e/r" . "r"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (cl-flet ((jump (rel)
                  (with-current-buffer buffer
                    (dirdiff-test--goto rel)
                    (save-window-excursion
                      (dirdiff-dired-jump)
                      (prog1 (list (file-name-as-directory default-directory)
                                   (ignore-errors (dired-get-filename)))
                        (kill-buffer))))))
        (should (equal (jump "d/f") (list (file-name-as-directory (expand-file-name "d" left))
                                         (expand-file-name "d/f" left))))
        ;; Not on the active side: the nearest directory above it there.
        (should (equal (car (jump "d/e/r")) (file-name-as-directory (expand-file-name "d" left))))
        (with-current-buffer buffer (dirdiff--set-side 'right))
        (should (equal (jump "d/e/r") (list (file-name-as-directory (expand-file-name "d/e" right))
                                           (expand-file-name "d/e/r" right))))
        ;; Not on the right side at all: the root.
        (should (equal (car (jump "l")) (file-name-as-directory right)))))))

(ert-deftest dirdiff-test-copy-filename ()
  (dirdiff-test--with-dirs '(("d/f" . "1")) '(("d/f" . "2") ("d/r" . "r"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (let ((kill-ring nil))
        (dirdiff-test--goto "d/f")
        (dirdiff-copy-filename-as-kill)
        (should (equal (current-kill 0) "f"))
        (dirdiff-copy-filename-as-kill '(4))
        (should (equal (current-kill 0) "d/f"))
        (dirdiff-copy-filename-as-kill 0)
        (should (equal (current-kill 0) (expand-file-name "d/f" left)))
        (dirdiff--set-side 'right)
        (dirdiff-copy-filename-as-kill 0)
        (should (equal (current-kill 0) (expand-file-name "d/f" right)))
        ;; Only on the right: the right name even when the left is active.
        (dirdiff--set-side 'left)
        (dirdiff-test--goto "d/r")
        (dirdiff-copy-filename-as-kill 0)
        (should (equal (current-kill 0) (expand-file-name "d/r" right)))))))

(ert-deftest dirdiff-test-copy-file ()
  (dirdiff-test--with-dirs '(("f" . "left") ("only/deep/new" . "n")) '(("f" . "right"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (dirdiff-test--goto "f")
      (dirdiff-copy-to-right)
      (should (equal (dirdiff-test--read (expand-file-name "f" right)) "left"))
      (should (eq (dirdiff-test--status dirdiff--session "f") 'same))
      ;; Copying a file inside a one-sided directory creates the parents
      ;; and updates the whole one-sided subtree.
      (dirdiff-test--goto "only/deep/new")
      (dirdiff-copy-to-right)
      (should (file-exists-p (expand-file-name "only/deep/new" right)))
      (should (eq (dirdiff-test--status dirdiff--session "only") 'same))
      (should (eq (dirdiff-node-status (dirdiff-session-tree dirdiff--session)) 'same))
      (should (string-prefix-p " identical" (dirdiff--mode-line))))))

(ert-deftest dirdiff-test-copy-directory-replaces ()
  (dirdiff-test--with-dirs '(("d/a" . "a") ("d/b" . "b")) '(("d/a" . "old") ("d/extra" . "x"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (dirdiff-test--goto "d")
      (dirdiff-copy-to-right)
      (should (equal (directory-files (expand-file-name "d" right) nil "\\`[^.]") '("a" "b")))
      (should (eq (dirdiff-test--status dirdiff--session "d") 'same)))))

;; Review: replacing or deleting a directory removed what the
;; comparison does not show, such as .git.
(ert-deftest dirdiff-test-copy-directory-keeps-uncompared ()
  (dirdiff-test--with-dirs '(("d/a" . "a") ("d/same" . "s"))
      '(("d/a" . "old") ("d/same" . "s") ("d/extra" . "x") ("d/.git/HEAD" . "h"))
    (let ((delete-by-moving-to-trash nil)
          (time (encode-time '(0 0 12 1 1 2020 nil nil t))))
      (set-file-times (expand-file-name "d/same" right) time)
      (dirdiff-test--in-buffer (dirdiff-test--session left right)
        (dirdiff-test--goto "d")
        (dirdiff-copy-to-right)
        (should (equal (directory-files (expand-file-name "d" right) nil "\\`[^.]")
                       '("a" "same")))
        (should (equal (dirdiff-test--read (expand-file-name "d/a" right)) "a"))
        (should (file-exists-p (expand-file-name "d/.git/HEAD" right)))
        ;; Identical files are left alone.
        (should (time-equal-p (file-attribute-modification-time
                               (file-attributes (expand-file-name "d/same" right)))
                              time))
        ;; Deleting keeps .git, and so the directory.
        (dirdiff--set-side 'right)
        (let ((messages (dirdiff-test--messages #'dirdiff-delete)))
          (should (cl-some (lambda (m) (string-match-p "Left alone: d/" m)) messages)))
        (should (equal (directory-files (expand-file-name "d" right) nil "\\`[^.]") nil))
        (should (file-exists-p (expand-file-name "d/.git/HEAD" right)))
        ;; Both sides still have d/, but only the left one has files.
        (should (eq (dirdiff-test--status dirdiff--session "d/a") 'left))))))

;; Review: copying or deleting a git submodule wiped its checkout.
(ert-deftest dirdiff-test-opaque-entries-are-not-touched ()
  (dirdiff-test--with-dirs '(("m/f" . "1") ("d/m/f" . "1") ("d/x" . "new"))
      '(("m/f" . "2") ("d/m/f" . "2") ("d/x" . "old"))
    (let ((delete-by-moving-to-trash nil))
      (dirdiff-test--in-buffer (dirdiff-test--session left right)
        (dolist (rel '("m" "d/m"))
          (let ((node (dirdiff-test--find dirdiff--session rel)))
            (setf (dirdiff-entry-type (dirdiff-node-right node)) 'opaque
                  (dirdiff-node-children node) nil)))
        (dirdiff-test--goto "m")
        (should-error (dirdiff-copy-to-right) :type 'user-error)
        (dirdiff--set-side 'right)
        (should-error (dirdiff-delete) :type 'user-error)
        ;; Inside a directory, an opaque entry is left alone.
        (dirdiff-test--goto "d")
        (dirdiff-copy-to-right)
        (should (equal (dirdiff-test--read (expand-file-name "d/x" right)) "new"))
        (should (equal (dirdiff-test--read (expand-file-name "d/m/f" right)) "2"))
        (should (equal (dirdiff-test--read (expand-file-name "m/f" right)) "2"))))))

;; Review: copy decided from the comparison, not from what is on disk.
(ert-deftest dirdiff-test-copy-checks-disk ()
  (dirdiff-test--with-dirs '(("f" . "new") ("d/g" . "g")) '()
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (dirdiff-test--write right '(("f" . "made later") ("d/other" . "o")))
      (dirdiff-test--goto "f")
      (should-error (dirdiff-copy-to-right) :type 'user-error)
      (should (equal (dirdiff-test--read (expand-file-name "f" right)) "made later"))
      (dirdiff-test--goto "d")
      (should-error (dirdiff-copy-to-right) :type 'user-error)
      ;; An empty directory is fine.
      (delete-file (expand-file-name "d/other" right))
      (dirdiff-copy-to-right)
      (should (equal (dirdiff-test--read (expand-file-name "d/g" right)) "g")))))

;; Review: an unreadable directory aborted the whole comparison.
(ert-deftest dirdiff-test-unreadable-directory ()
  (skip-unless (not (zerop (user-uid))))
  (dirdiff-test--with-dirs '(("locked/f" . "1") ("ok" . "1")) '(("locked/f" . "1") ("ok" . "2"))
    (let ((locked (expand-file-name "locked" left)))
      (set-file-modes locked #o000)
      (unwind-protect
          (let ((s (dirdiff-test--session left right)))
            (should (eq (dirdiff-test--status s "ok") 'changed))
            (should (eq (dirdiff-test--status s "locked") 'changed))
            (should (dirdiff-node-error (dirdiff-test--find s "locked")))
            (should (string-match-p "could not read locked/" (dirdiff--summary s)))
            (dirdiff-test--in-buffer s
              (should (string-match-p "(unreadable)" (buffer-string)))
              (dirdiff-test--goto "locked")
              (should-error (dirdiff-copy-to-left) :type 'user-error)))
        (set-file-modes locked #o755)))))

(ert-deftest dirdiff-test-control-characters-in-names ()
  (dirdiff-test--with-dirs '(("a\nb" . "1") ("c" . "1")) '(("a\nb" . "2") ("c" . "2"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (should (= (count-lines (point-min) (point-max)) 2))
      (should (string-match-p "a\\^Jb" (buffer-string))))))

;; Review: the whitespace and line ending options did not reach ediff.
(ert-deftest dirdiff-test-ediff-options ()
  (require 'ediff)
  (dirdiff-test--with-dirs '(("f" . "a b\n")) '(("f" . "a  b\n"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right :ignore-whitespace t
                                                    :ignore-line-endings t)
      (let ((before (default-value 'ediff-actual-diff-options))
            options)
        (cl-letf (((symbol-function 'ediff-files)
                   (lambda (&rest _)
                     (setq options (default-value 'ediff-actual-diff-options)))))
          (dirdiff-test--goto "f")
          (dirdiff-open))
        (should (string-match-p "-w" options))
        (should (string-match-p "--strip-trailing-cr" options))
        (should (equal (default-value 'ediff-actual-diff-options) before))))))

(ert-deftest dirdiff-test-find-node ()
  (dirdiff-test--with-dirs '(("a/b/c" . "1")) '(("a/b/c" . "2"))
    (let ((s (dirdiff-test--session left right)))
      (should (eq (dirdiff--find-node s "a/b/c") (dirdiff-test--find s "a/b/c")))
      (should-not (dirdiff--find-node s "a/x")))))

(ert-deftest dirdiff-test-copy-to-left-and-conflict ()
  (dirdiff-test--with-dirs '(("x" . "file")) '(("x/inner" . "i"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (dirdiff-test--goto "x")
      (dirdiff-copy-to-left)
      (should (file-directory-p (expand-file-name "x" left)))
      (should (eq (dirdiff-test--status dirdiff--session "x") 'same)))))

(ert-deftest dirdiff-test-delete ()
  (dirdiff-test--with-dirs '(("f" . "1") ("d/g" . "g")) '(("f" . "2"))
    (let ((delete-by-moving-to-trash nil))
      (dirdiff-test--in-buffer (dirdiff-test--session left right)
        (dirdiff-test--goto "f")
        (dirdiff-switch-side)
        (dirdiff-delete)
        (should-not (file-exists-p (expand-file-name "f" right)))
        (should (eq (dirdiff-test--status dirdiff--session "f") 'left))
        (dirdiff-test--goto "d")
        (dirdiff--set-side 'left)
        (dirdiff-delete)
        (should-not (file-exists-p (expand-file-name "d" left)))
        (should-not (dirdiff-test--find dirdiff--session "d"))))))

;; Request: copying from a side where the entry is missing copies the
;; deletion, asking like overwriting does.
(ert-deftest dirdiff-test-copy-deletion ()
  (dirdiff-test--with-dirs '() '(("r" . "r") ("d/x" . "x"))
    (let ((delete-by-moving-to-trash nil))
      (dirdiff-test--in-buffer (dirdiff-test--session left right)
        (let (prompts)
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (p) (push p prompts) nil)))
            (dirdiff-test--goto "r")
            (dirdiff-copy-to-right))
          (should (equal prompts
                         '("r is only on the right side.  Delete it there permanently? ")))
          (should (file-exists-p (expand-file-name "r" right))))
        (dirdiff-copy-to-right)
        (should-not (file-exists-p (expand-file-name "r" right)))
        (should-not (dirdiff-test--find dirdiff--session "r"))
        (dirdiff-test--goto "d")
        (dirdiff-copy-to-right)
        (should-not (file-exists-p (expand-file-name "d" right)))
        ;; Revision sides and git difftool copies cannot be changed.
        (setf (dirdiff-source-writable (dirdiff-session-right dirdiff--session)) 'working-tree)
        (dirdiff-test--write right '(("w" . "w")))
        (dirdiff-refresh)
        (dirdiff-test--goto "w")
        (should-error (dirdiff-copy-to-right) :type 'user-error)))))

(ert-deftest dirdiff-test-replace-asks-for-confirmation ()
  (dirdiff-test--with-dirs '(("f" . "new") ("g" . "g")) '(("f" . "old"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (let (prompts)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (p) (push p prompts) nil))
                  ((symbol-function 'y-or-n-p) (lambda (p) (push p prompts) nil)))
          (let ((delete-by-moving-to-trash t))
            (dirdiff-test--goto "f")
            (dirdiff-copy-to-right))
          (let ((delete-by-moving-to-trash nil))
            (dirdiff-copy-to-right))
          ;; Nothing is in the way: the quick question.
          (dirdiff-test--goto "g")
          (dirdiff-copy-to-right))
        (should (equal (nreverse prompts)
                       '("Copy f to the right side, moving the file there to the trash? "
                         "Copy f to the right side, deleting the file there permanently? "
                         "Copy g to the right side? ")))
        ;; A directory replacing a file says so.
        (setq prompts nil)
        (dirdiff-test--write left '(("d/x" . "x")))
        (dirdiff-test--write right '(("d" . "file")))
        (dirdiff-refresh)
        (dirdiff-test--goto "d")
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (p) (push p prompts) nil)))
          (let ((delete-by-moving-to-trash t))
            (dirdiff-copy-to-right)))
        (should (equal prompts '("Copy d/ to the right side, moving the file there to the trash? ")))
        ;; Declined, so nothing changed.
        (should (equal (dirdiff-test--read (expand-file-name "f" right)) "old"))
        (should-not (file-exists-p (expand-file-name "g" right)))))))

;; Bug: copying onto a symlink wrote into the file it points to, even
;; outside the compared tree.
(ert-deftest dirdiff-test-copy-replaces-symlink ()
  (dirdiff-test--with-dirs '(("f" . "new")) '(("outside/real" . "precious") ("f" link . "outside/real"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (dirdiff-test--goto "f")
      (dirdiff-copy-to-right)
      (should (equal (dirdiff-test--read (expand-file-name "outside/real" right)) "precious"))
      (should-not (file-symlink-p (expand-file-name "f" right)))
      (should (equal (dirdiff-test--read (expand-file-name "f" right)) "new")))))

(defun dirdiff-test--messages (thunk)
  "Call THUNK and return its messages; fail if ediff is started."
  (let (messages)
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages)))
              ((symbol-function 'ediff-files)
               (lambda (&rest _) (error "Ediff was started"))))
      (funcall thunk))
    messages))

;; Bug: RET on two symlinks to directories ran ediff on directories.
(defvar ediff-quit-hook)
(defvar ediff-after-quit-hook-internal)

;; Request: start from the command line like meld, exiting on quit.
(ert-deftest dirdiff-test-command-line ()
  (dirdiff-test--with-dirs '(("f" . "1")) '(("f" . "2"))
    (let ((command-line-default-directory root)
          (command-line-args-left '("left" "right" "--next"))
          (ediff-quit-hook nil)
          scheduled compared)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_time _repeat fn &rest _)
                   (when (eq fn #'save-buffers-kill-emacs) (push fn scheduled)))))
        (let ((buffer (dirdiff-command-line)))
          (should (equal command-line-args-left '("--next")))
          (should (buffer-live-p buffer))
          (should-not scheduled)
          (kill-buffer buffer)
          (should (equal scheduled '(save-buffers-kill-emacs)))))
      ;; Files go to ediff, and quitting ediff exits too.
      (setq command-line-args-left '("left/f" "right/f") scheduled nil)
      (cl-letf (((symbol-function 'ediff-files)
                 (lambda (&rest files) (setq compared files)))
                ((symbol-function 'run-at-time)
                 (lambda (_time _repeat fn &rest _)
                   (when (eq fn #'save-buffers-kill-emacs) (push fn scheduled)))))
        (dirdiff-command-line)
        (should (equal compared (list (expand-file-name "f" left)
                                      (expand-file-name "f" right))))
        (run-hooks 'ediff-quit-hook)
        (should (equal scheduled '(save-buffers-kill-emacs))))
      (setq command-line-args-left '("left"))
      (should-error (dirdiff-command-line)))))

;; Requests: a file on one side only is diffed against an empty file
;; (it used to be visited), and its missing side is struck through.
(ert-deftest dirdiff-test-one-sided-file ()
  (dirdiff-test--with-dirs '(("only.el" . "x") ("bin" . "\0")) '()
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (dirdiff-test--goto "only.el")
      (beginning-of-line)
      (should (eq (get-text-property (1- (search-forward "only")) 'face) 'dirdiff-new))
      (should (eq (get-text-property (1- (search-forward "only")) 'face) 'dirdiff-absent))
      (should (face-attribute 'dirdiff-absent :strike-through))
      (require 'ediff)                  ; or loading it would undo the mock
      (let (args)
        (cl-letf (((symbol-function 'ediff-files) (lambda (&rest a) (setq args a))))
          (dirdiff-open))
        (pcase-let ((`(,a ,b ,startup) args))
          (should (equal a (expand-file-name "only.el" left)))
          (should (equal (file-name-nondirectory b) "only.el"))
          (should (equal (dirdiff-test--read b) ""))
          ;; Quitting ediff removes the empty file.
          (with-temp-buffer
            (mapc #'funcall startup)
            (funcall (car (last ediff-after-quit-hook-internal))))
          (should-not (file-exists-p b))))
      (dirdiff-test--goto "bin")
      (should (equal (dirdiff-test--messages #'dirdiff-open)
                     '("Binary file on the left only"))))))

;; Request: comparing the directories of two Dired windows side by side
;; uses the space of both, and quitting restores them.
(ert-deftest dirdiff-test-replace-dired-windows ()
  (dirdiff-test--with-dirs '(("f" . "1")) '(("f" . "2"))
    (save-window-excursion
      (delete-other-windows)
      (let* ((other (get-buffer-create "*dirdiff-test-other*"))
             (bottom (split-window nil nil 'below))
             (right-window (split-window nil nil 'right))
             (left-dired (dired-noselect left))
             (right-dired (dired-noselect right)))
        (set-window-buffer bottom other)
        (set-window-buffer (selected-window) left-dired)
        (set-window-buffer right-window right-dired)
        (let* ((width (+ (window-total-width) (window-total-width right-window)))
               (buffer (with-current-buffer left-dired (dirdiff left right))))
          (unwind-protect
              (progn
                (should (eq (window-buffer) buffer))
                (should (= (window-total-width) width))
                (should (= (length (window-list)) 2))
                (should (eq (window-buffer bottom) other))
                (with-current-buffer buffer (dirdiff-quit))
                (should-not (buffer-live-p buffer))
                (should (equal (mapcar #'window-buffer (window-list))
                               (list left-dired right-dired other))))
            (when (buffer-live-p buffer) (kill-buffer buffer))
            (mapc #'kill-buffer (list other left-dired right-dired))))))))

;; Request: v visits in this window, o in the other one.
(ert-deftest dirdiff-test-replace-dired-windows-error ()
  (dirdiff-test--with-dirs '(("f" . "1")) '(("f" . "2"))
    (save-window-excursion
      (delete-other-windows)
      (let* ((right-window (split-window nil nil 'right))
             (left-dired (dired-noselect left))
             (right-dired (dired-noselect right)))
        (set-window-buffer (selected-window) left-dired)
        (set-window-buffer right-window right-dired)
        (unwind-protect
            (progn
              ;; C-g while comparing takes the same path as an error.
              (cl-letf (((symbol-function 'dirdiff--build-tree)
                         (lambda (&rest _) (error "Boom"))))
                (should-error (with-current-buffer left-dired (dirdiff left right))))
              (should (equal (mapcar #'window-buffer (window-list))
                             (list left-dired right-dired))))
          (mapc #'kill-buffer (list left-dired right-dired)))))))

(ert-deftest dirdiff-test-visit ()
  (dirdiff-test--with-dirs '(("f" . "1")) '(("f" . "2") ("new" . "n"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (let (visited)
        (cl-letf (((symbol-function 'find-file)
                   (lambda (f &rest _) (push (cons 'this f) visited)))
                  ((symbol-function 'find-file-other-window)
                   (lambda (f &rest _) (push (cons 'other f) visited))))
          (dirdiff-test--goto "f")
          (execute-kbd-macro "v")
          (execute-kbd-macro "o")
          ;; Missing on the active side: visit the other one.
          (dirdiff-test--goto "new")
          (execute-kbd-macro "v"))
        (should (equal (reverse visited)
                       `((this . ,(expand-file-name "f" left))
                         (other . ,(expand-file-name "f" left))
                         (this . ,(expand-file-name "new" right)))))))))

(ert-deftest dirdiff-test-open-links ()
  (dirdiff-test--with-dirs '(("d/x" . "x") ("l" link . "d")) '(("e/x" . "x") ("l" link . "e"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (dirdiff-test--goto "l")
      (should (equal (dirdiff-test--messages #'dirdiff-open)
                     '("Symbolic links are different"))))))

;; Request: with core.symlinks false (Windows), git copies the working
;; tree's files instead of linking to them, and copies changes back.
(ert-deftest dirdiff-test-difftool-copies ()
  (dirdiff-test--with-dirs
      '(("copied" . "old") ("temp" . "a") ("new" . "n"))
      '(("copied" . "current") ("temp" . "b"))
    (let ((worktree (expand-file-name "worktree/" root)))
      (dirdiff-test--write worktree '(("copied" . "current") ("temp" . "changed since")))
      (let* ((process-environment (cons (concat "GIT_WORK_TREE=" worktree)
                                        process-environment))
             (session (dirdiff--difftool-session left right)))
        (should (eq (dirdiff-source-writable (dirdiff-session-right session)) 'working-tree))
        (dirdiff-test--in-buffer session
          (dirdiff-test--goto "copied")
          (set-file-times (expand-file-name "copied" left) 0)
          (dirdiff-copy-to-right)
          (should (equal (dirdiff-test--read (expand-file-name "copied" right)) "old"))
          ;; A new time, so that git sees the change.
          (should (time-less-p (time-subtract nil 60)
                               (file-attribute-modification-time
                                (file-attributes (expand-file-name "copied" right)))))
          (dirdiff-test--goto "temp")
          (should-error (dirdiff-copy-to-right) :type 'user-error)
          (dirdiff-test--goto "new")
          (should-error (dirdiff-copy-to-right) :type 'user-error)))
      ;; Without GIT_WORK_TREE, nothing is known to be copied back.
      (let ((process-environment (cons "GIT_WORK_TREE" process-environment)))
        (should-not (dirdiff-source-writable
                     (dirdiff-session-right (dirdiff--difftool-session left right))))))))

;; Request: git difftool runs Emacs directly, without a script.
(ert-deftest dirdiff-test-difftool-command-line ()
  (dirdiff-test--with-dirs '(("f" . "1")) '(("f" . "2"))
    (let ((command-line-default-directory root)
          (command-line-args-left '("left" "right"))
          scheduled)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_time _repeat fn &rest _) (push fn scheduled))))
        (let ((buffer (dirdiff-difftool-command-line)))
          (with-current-buffer buffer
            (should (equal (dirdiff-dir-source-root (dirdiff-session-right dirdiff--session))
                           right))
            (should-not (dirdiff-source-writable (dirdiff-session-left dirdiff--session))))
          (should-not command-line-args-left)
          (kill-buffer buffer)
          (should (equal scheduled '(save-buffers-kill-emacs))))
        (should-error (dirdiff-difftool-command-line)))
      ;; Without --dir-diff, git passes two files: ediff them.
      (let ((command-line-args-left '("left/f" "right/f"))
            (ediff-quit-hook nil)
            compared)
        (cl-letf (((symbol-function 'ediff-files)
                   (lambda (a b &rest _) (setq compared (list a b)))))
          (dirdiff-difftool-command-line))
        (should (equal compared (list (expand-file-name "f" left) (expand-file-name "f" right))))
        (should (memq #'dirdiff--exit ediff-quit-hook))))))

;; Bug: git difftool's left side is a temporary snapshot and its right
;; side links into the working tree, yet both were fully writable.
(ert-deftest dirdiff-test-difftool-sides ()
  (dirdiff-test--with-dirs
      '(("linked" . "old") ("plain" . "a") ("new" . "n"))
      '(("worktree/linked" . "current") ("linked" link . "worktree/linked") ("plain" . "b"))
    (let ((session (dirdiff--difftool-session left right)))
      (should-not (dirdiff-source-writable (dirdiff-session-left session)))
      (dirdiff-test--in-buffer session
        ;; Copying onto a file linked to the working tree changes that file.
        (dirdiff-test--goto "linked")
        (dirdiff-copy-to-right)
        (should (equal (dirdiff-test--read (expand-file-name "worktree/linked" right)) "old"))
        (should (file-symlink-p (expand-file-name "linked" right)))
        ;; Changes to the temporary files would be lost, so refuse them.
        (dirdiff-test--goto "plain")
        (should-error (dirdiff-copy-to-right) :type 'user-error)
        (should-error (dirdiff-copy-to-left) :type 'user-error)
        (dirdiff-test--goto "new")
        (should-error (dirdiff-copy-to-right) :type 'user-error)
        (dirdiff-test--goto "linked")
        (dirdiff--set-side 'right)
        (should-error (dirdiff-delete) :type 'user-error)))))

;; Request: files that differ only in line endings or in the
;; executable bit can be treated as identical.
(ert-deftest dirdiff-test-line-endings-and-modes ()
  (dirdiff-test--with-dirs '(("crlf" . "a\r\nb\r\n") ("cr" . "a\rb\n") ("x" . "s"))
      '(("crlf" . "a\nb\n") ("cr" . "a\nb\n") ("x" . "s"))
    (set-file-modes (expand-file-name "x" right) #o755)
    (dolist (large '(nil t))
      (let* ((dirdiff--large-file-size (if large 1 dirdiff--large-file-size))
             (s (dirdiff-test--session left right)))
        (should (eq (dirdiff-test--status s "crlf") 'same))
        (should (eq (dirdiff-test--status s "cr") 'changed))
        (should (eq (dirdiff-test--status s "x") 'same))))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (execute-kbd-macro "e")
      (should (eq (dirdiff-test--status dirdiff--session "crlf") 'changed))
      (should (eq (dirdiff-test--status dirdiff--session "x") 'same))
      (execute-kbd-macro "x")
      (should (eq (dirdiff-test--status dirdiff--session "x") 'changed))
      (should (string-match-p "\\[eol\\] \\[x\\]" (dirdiff--mode-line)))
      (dirdiff-test--goto "x")
      (should (equal (dirdiff-test--messages #'dirdiff-open)
                     '("The contents are identical; only the file mode differs (executable on the right)"))))))

;; Request: a clear textual marker of the active side.
(ert-deftest dirdiff-test-active-marker ()
  (dirdiff-test--with-dirs '(("f" . "1")) '(("f" . "2"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (cl-flet ((marker-side ()
                  (let ((o (cl-find-if (lambda (o) (overlay-get o 'display))
                                       (overlays-in (pos-bol) (pos-eol)))))
                    (and (equal (substring-no-properties (overlay-get o 'display)) "▶")
                         (get-text-property (overlay-start o) 'dirdiff-side)))))
        (should (eq (marker-side) 'left))
        (should (string-prefix-p "▶ L" (dirdiff--header-line)))
        (execute-kbd-macro (kbd "TAB"))
        (should (eq (marker-side) 'right))
        (should (string-match-p "\\`  L .*▶ R" (dirdiff--header-line)))))))

;; Request: quitting an ediff with changes saves them (asking first)
;; and compares the files again.
(ert-deftest dirdiff-test-save-after-ediff ()
  (dirdiff-test--with-dirs '(("f" . "1\n")) '(("f" . "2\n"))
    (require 'ediff)
    (dolist (answer '(nil t))
      (dirdiff-test--in-buffer (dirdiff-test--session left right)
        (dirdiff-test--goto "f")
        (let (startup asked)
          (cl-letf (((symbol-function 'ediff-files) (lambda (_a _b s) (setq startup s))))
            (dirdiff-open))
          (with-current-buffer (find-file-noselect (expand-file-name "f" right))
            (erase-buffer)
            (insert "1\n"))
          (cl-letf (((symbol-function 'map-y-or-n-p)
                     (lambda (_prompter actor list &rest _)
                       (setq asked t)
                       (when answer (mapc actor list))
                       (if answer (length list) 0))))
            (with-temp-buffer
              (mapc #'funcall startup)
              (funcall (car (last ediff-after-quit-hook-internal)))))
          (should asked)
          (should (eq (dirdiff-test--status dirdiff--session "f")
                      (if answer 'same 'changed)))
          (let ((b (get-file-buffer (expand-file-name "f" right))))
            (with-current-buffer b (set-buffer-modified-p nil))
            (kill-buffer b)))))))

;; Bug: with the right side reached through a symlink and
;; `find-file-visit-truename', changes there were not saved.
(ert-deftest dirdiff-test-save-after-ediff-truename ()
  (dirdiff-test--with-dirs '(("f" . "1\n")) '(("real/f" . "2\n"))
    (require 'ediff)
    (let ((link (expand-file-name "link" root))
          (find-file-visit-truename t)
          (dirdiff-save-after-ediff t))
      (make-symbolic-link (expand-file-name "real" right) link)
      (dirdiff-test--in-buffer (dirdiff-test--session left link)
        (dirdiff-test--goto "f")
        (let (startup)
          (cl-letf (((symbol-function 'ediff-files) (lambda (_a _b s) (setq startup s))))
            (dirdiff-open))
          (let ((b (find-file-noselect (expand-file-name "f" link))))
            (should (equal (buffer-file-name b) (expand-file-name "real/f" right)))
            (with-current-buffer b
              (erase-buffer)
              (insert "1\n"))
            (with-temp-buffer
              (mapc #'funcall startup)
              (funcall (car (last ediff-after-quit-hook-internal))))
            (should (equal (dirdiff-test--read (expand-file-name "real/f" right)) "1\n"))
            (should (eq (dirdiff-test--status dirdiff--session "f") 'same))
            (kill-buffer b)))))))

;;;; Git

(defmacro dirdiff-test--with-repo (&rest body)
  "Run BODY in a new git repository with two commits.
Commit 1: a.txt, ws.txt, dir/g, same.txt, bin.  Commit 2 changes
a.txt, changes whitespace in ws.txt, deletes dir/g and adds new."
  (declare (indent 0))
  `(let* ((repo (file-name-as-directory (make-temp-file "dirdiff-git-test-" t)))
          (default-directory repo)
          (process-environment (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t"
                                         "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t")
                                       process-environment)))
     (unwind-protect
         (cl-flet ((git (&rest args) (apply #'dirdiff-git--run repo args)))
           (git "init" "-q")
           (dirdiff-test--write repo '(("a.txt" . "a\nb\n") ("ws.txt" . "x y\n")
                                       ("dir/g" . "1") ("same.txt" . "s") ("bin" . "\0\1")))
           (git "add" ".")
           (git "commit" "-q" "-m" "1")
           (dirdiff-test--write repo '(("a.txt" . "a\nc\n") ("ws.txt" . "x  y\n") ("new" . "n")))
           (delete-file "dir/g")
           (git "add" "-A")
           (git "commit" "-q" "-m" "2")
           ,@body)
       (delete-directory repo t))))

(defun dirdiff-test--git-session (repo left-rev right-rev &optional ignore-whitespace)
  "Return a compared session of REPO's LEFT-REV and RIGHT-REV.
With IGNORE-WHITESPACE, ignore whitespace."
  (let ((session (dirdiff-git--session repo left-rev right-rev)))
    (setf (dirdiff-session-ignore-whitespace session) ignore-whitespace)
    (dirdiff--build-tree session)
    session))

(ert-deftest dirdiff-test-git-revisions ()
  (dirdiff-test--with-repo
    (let ((s (dirdiff-test--git-session repo "HEAD~1" "HEAD")))
      (should (equal (dirdiff-test--statuses s)
                     '(("dir" . left) ("dir/g" . left) ("a.txt" . changed) ("bin" . same)
                       ("new" . right) ("same.txt" . same) ("ws.txt" . changed))))
      (should-not (dirdiff-source-writable (dirdiff-session-right s))))
    (let ((s (dirdiff-test--git-session repo "HEAD~1" "HEAD" t)))
      (should (eq (dirdiff-test--status s "ws.txt") 'same))
      (should (eq (dirdiff-test--status s "a.txt") 'changed)))))

(ert-deftest dirdiff-test-git-worktree ()
  (dirdiff-test--with-repo
    (dirdiff-test--write repo '(("same.txt" . "edited") ("untracked" . "u")
                                (".gitignore" . "ignored\n") ("ignored" . "i")))
    (delete-file "a.txt")
    ;; Touching a file without changing it must not make it "changed".
    (set-file-times (expand-file-name "new" repo) (current-time))
    (let ((s (dirdiff-test--git-session repo "HEAD" nil)))
      (should (equal (dirdiff-test--statuses s)
                     '((".gitignore" . right) ("a.txt" . left) ("bin" . same) ("new" . same)
                       ("same.txt" . changed) ("untracked" . right) ("ws.txt" . same))))
      (should (dirdiff-source-writable (dirdiff-session-right s))))))

(ert-deftest dirdiff-test-git-files-and-copy ()
  (dirdiff-test--with-repo
    (let* ((s (dirdiff-test--git-session repo "HEAD~1" nil))
           (file (dirdiff-test--local-file s "a.txt" 'left)))
      ;; Revision files are extracted read-only.
      (should (equal (dirdiff-test--read file) "a\nb\n"))
      (should-not (file-writable-p file))
      (dirdiff-test--in-buffer s
        ;; Copy from the revision to the working tree.
        (dirdiff-test--goto "a.txt")
        (dirdiff-copy-to-right)
        (should (equal (dirdiff-test--read (expand-file-name "a.txt" repo)) "a\nb\n"))
        (should (eq (dirdiff-test--status dirdiff--session "a.txt") 'same))
        (dirdiff-test--goto "dir")
        (dirdiff-copy-to-right)
        (should (equal (dirdiff-test--read (expand-file-name "dir/g" repo)) "1"))
        (should (eq (dirdiff-test--status dirdiff--session "dir") 'same))
        ;; The revision side is read-only.
        (dirdiff-test--goto "new")
        (should-error (dirdiff-copy-to-left) :type 'user-error)
        (dirdiff--set-side 'left)
        (should-error (dirdiff-delete) :type 'user-error))
      ;; Killing the buffer removed the extracted files.
      (should-not (file-exists-p file)))))

(ert-deftest dirdiff-test-git-visit-revision-directory ()
  (dirdiff-test--with-repo
    (dirdiff-test--in-buffer (dirdiff-test--git-session repo "HEAD~1" nil)
      (dirdiff-test--goto "dir")
      (should-error (dirdiff-find-file) :type 'user-error))))

;; Review: copying from a revision skipped .gitattributes conversion.
(ert-deftest dirdiff-test-git-copy-applies-attributes ()
  (dirdiff-test--with-repo
    (cl-flet ((git (&rest args) (apply #'dirdiff-git--run repo args)))
      (dirdiff-test--write repo '((".gitattributes" . "*.txt eol=crlf\n")))
      (git "add" ".gitattributes")
      (git "commit" "-q" "-m" "3")
      (delete-file (expand-file-name "a.txt" repo))
      (dirdiff-test--in-buffer (dirdiff-test--git-session repo "HEAD" nil)
        (dirdiff-test--goto "a.txt")
        (dirdiff-copy-to-right)
        (should (equal (dirdiff-test--read (expand-file-name "a.txt" repo)) "a\r\nc\r\n"))))))

;; Review: extracted revision files were left behind when Emacs exited.
(ert-deftest dirdiff-test-git-cleanup-on-exit ()
  (dirdiff-test--with-repo
    (let* ((s (dirdiff-test--git-session repo "HEAD~1" nil))
           (file (dirdiff-test--local-file s "a.txt" 'left))
           (buffer (dirdiff-show-session s))
           (visiting (find-file-noselect file)))
      (unwind-protect
          (progn
            (should (memq #'dirdiff--cleanup-all kill-emacs-hook))
            (dirdiff--cleanup-all)
            (should-not (file-exists-p file))
            (should-not (buffer-live-p visiting)))
        (kill-buffer buffer)))))

(ert-deftest dirdiff-test-git-copy-filename ()
  (dirdiff-test--with-repo
    (let ((s (dirdiff-test--git-session repo "HEAD~1" nil)))
      (dirdiff-test--in-buffer s
        (let ((kill-ring nil))
          (dirdiff-test--goto "dir/g")
          (dirdiff-copy-filename-as-kill 0)
          (should (equal (current-kill 0)
                         (concat (string-trim (dirdiff-git--run repo "rev-parse" "HEAD~1")) ":dir/g")))
          (dirdiff-test--goto "a.txt")
          (dirdiff--set-side 'right)
          (dirdiff-copy-filename-as-kill 0)
          (should (equal (current-kill 0) (expand-file-name "a.txt" repo))))
        (dirdiff--set-side 'left)
        (should-error (dirdiff-dired-jump) :type 'user-error)))))

(defun dirdiff-test--local-file (session rel side)
  "Return the local file of the node of SESSION at REL on SIDE."
  (let ((dirdiff--session session))
    (dirdiff--local-file (dirdiff-test--find session rel) side)))

(ert-deftest dirdiff-test-git-root-commit ()
  (dirdiff-test--with-repo
    (let ((default-directory repo))
      (cl-letf (((symbol-function 'dirdiff-show-session)
                 (lambda (session &rest _)
                   (dirdiff--build-tree session)
                   (dirdiff-test--statuses session))))
        (should (equal (dirdiff-git "HEAD~1^!")
                       '(("dir" . right) ("dir/g" . right) ("a.txt" . right) ("bin" . right)
                         ("same.txt" . right) ("ws.txt" . right))))))))

;; Bug: in git comparisons, RET on a changed binary file ran ediff.
(ert-deftest dirdiff-test-git-open-binary ()
  (dirdiff-test--with-repo
    (dirdiff-test--write repo '(("bin" . "\0\2")))
    (let ((dirdiff-new-frame nil))
      (dirdiff-test--in-buffer (dirdiff-test--git-session repo "HEAD" nil)
        (dirdiff-test--goto "bin")
        (should (equal (dirdiff-test--messages #'dirdiff-open)
                       '("Binary files are different")))))))

;; Bugs: an untracked symlink whose path is a symlink in the revision
;; crashed the comparison, and a quick binary comparison against a
;; revision compared the time of the extracted copy.
(ert-deftest dirdiff-test-git-untracked-link-and-binary ()
  (dirdiff-test--with-repo
    (cl-flet ((git (&rest args) (apply #'dirdiff-git--run repo args)))
      (make-symbolic-link "nowhere" (expand-file-name "lnk" repo))
      (dirdiff-test--write repo '(("bin2" . "\0same")))
      (git "add" "lnk" "bin2")
      (git "commit" "-q" "-m" "3")
      (git "rm" "-q" "--cached" "lnk" "bin2"))
    (let ((s (dirdiff-test--git-session repo "HEAD" nil)))
      (should (eq (dirdiff-test--status s "lnk") 'same))
      (should (eq (dirdiff-test--status s "bin2") 'same)))))

;; Bug: a change of only the executable bit showed as changed, and RET
;; ran an ediff that found no differences.  Request: ignore such
;; changes, as an option.
(ert-deftest dirdiff-test-git-mode-only-change ()
  (dirdiff-test--with-repo
    (set-file-modes (expand-file-name "same.txt" repo) #o755)
    (dirdiff-git--run repo "add" "same.txt")
    (dirdiff-git--run repo "commit" "-q" "-m" "3")
    (dirdiff-test--write repo '(("ws.txt" . "x   y\n")))
    (set-file-modes (expand-file-name "ws.txt" repo) #o755)
    (dolist (revs '(("HEAD~1" "HEAD") ("HEAD~1" nil)))
      (let ((s (apply #'dirdiff-test--git-session repo revs)))
        (should (eq (dirdiff-test--status s "same.txt") 'same))))
    ;; Line endings, against the working tree.
    (dirdiff-test--write repo '(("a.txt" . "a\r\nc\r\n")))
    (let ((s (dirdiff-test--git-session repo "HEAD" nil)))
      (should (eq (dirdiff-test--status s "a.txt") 'same))
      (setf (dirdiff-session-ignore-line-endings s) nil)
      (dirdiff--build-tree s)
      (should (eq (dirdiff-test--status s "a.txt") 'changed)))
    ;; The mode and whitespace changed: same when both are ignored.
    (let ((s (dirdiff-git--session repo "HEAD" nil)))
      (setf (dirdiff-session-ignore-whitespace s) t)
      (dirdiff--build-tree s)
      (should (eq (dirdiff-test--status s "ws.txt") 'same))
      (setf (dirdiff-session-ignore-modes s) nil)
      (dirdiff--build-tree s)
      (should (eq (dirdiff-test--status s "ws.txt") 'changed)))
    (dirdiff-test--in-buffer (let ((dirdiff-ignore-file-modes nil))
                               (dirdiff-test--git-session repo "HEAD~1" nil))
      (dirdiff-test--goto "same.txt")
      (should (eq (dirdiff-test--status dirdiff--session "same.txt") 'changed))
      (should (equal (dirdiff-test--messages #'dirdiff-open)
                     '("The contents are identical; only the file mode differs (executable on the right)"))))))

(ert-deftest dirdiff-test-git-parse-range ()
  (dirdiff-test--with-repo
    (should (equal (dirdiff-git--parse-range "A..B") '("A" "B")))
    (should (equal (dirdiff-git--parse-range "A..") '("A" "HEAD")))
    (should (equal (dirdiff-git--parse-range "..B") '("HEAD" "B")))
    (should (equal (dirdiff-git--parse-range "HEAD~1") '("HEAD~1" nil)))
    (should (equal (dirdiff-git--parse-range "") '("HEAD" nil)))
    (should (equal (dirdiff-git--parse-range "HEAD^!") '("HEAD^" "HEAD")))
    (should (equal (dirdiff-git--parse-range "HEAD~1^!")
                   (list dirdiff-git--empty-tree "HEAD~1")))
    (should (equal (dirdiff-git--parse-range "HEAD~1...HEAD")
                   (list (string-trim (dirdiff-git--run repo "rev-parse" "HEAD~1")) "HEAD")))))

;; Bug: `D p' did not read a range the way the user's difftool keys
;; did (magit's reader, with `...' on a prefix argument).
(ert-deftest dirdiff-test-git-range-reader ()
  (dirdiff-test--with-repo
    (let ((default-directory repo)
          read compared)
      (cl-letf (((symbol-function 'magit-diff-read-range-or-commit)
                 (lambda (&rest args) (setq read args) "HEAD~1..HEAD"))
                ((symbol-function 'dirdiff-git-compare)
                 (lambda (&rest revs) (setq compared revs))))
        (let ((current-prefix-arg '(4)))
          (call-interactively #'dirdiff-git))
        (should (equal read '("Dirdiff range" nil (4))))
        (should (equal compared '("HEAD~1" "HEAD")))))))

(ert-deftest dirdiff-test-magit-setup ()
  "The keys replace existing suffixes, also when set up twice."
  (skip-unless (require 'magit-diff nil t))
  (transient-append-suffix 'magit-diff '(-1 -1 -1) '("D p" "Difftool" ignore))
  (dirdiff-magit-setup)
  (dirdiff-magit-setup)
  (let ((layout (format "%S" (get 'magit-diff 'transient--layout))))
    (should-not (string-search ":key \"D r\"" layout))
    (pcase-dolist (`(,key . ,command) '(("D p" . dirdiff-git)
                                        ("D h" . dirdiff-git-against-head)
                                        ("D w" . dirdiff-git-against-worktree)))
      (should (eq (plist-get (cdr (transient-get-suffix 'magit-diff key)) :command) command))
      (should (= 1 (with-temp-buffer
                     (insert layout)
                     (how-many (regexp-quote (format ":key %S" key)) (point-min))))))))

(provide 'dirdiff-test)
;;; dirdiff-test.el ends here
