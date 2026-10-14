;;; dirdiff-test.el --- Tests for dirdiff  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs --batch -Q -L . -l test/dirdiff-test.el -f ert-run-tests-batch-and-exit

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
  "Run BODY with `left' and `right' bound to new directories."
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
  (let ((session (apply #'dirdiff-session-create
                        :left (dirdiff-dir-source-create :root left :label "L" :writable t)
                        :right (dirdiff-dir-source-create :root right :label "R" :writable t)
                        options)))
    (dirdiff--build-tree session)
    session))

(defun dirdiff-test--find (session rel)
  (catch 'found
    (dirdiff--walk (dirdiff-session-tree session)
                   (lambda (n) (when (equal (dirdiff-node-rel n) rel) (throw 'found n))))
    nil))

(defun dirdiff-test--status (session rel)
  (dirdiff-node-status (or (dirdiff-test--find session rel) (error "No node %s" rel))))

(defun dirdiff-test--statuses (session)
  "Return an alist (REL . STATUS) of all nodes of SESSION, in display order."
  (let (result)
    (dirdiff--walk (dirdiff-session-tree session)
                   (lambda (n) (push (cons (dirdiff-node-rel n) (dirdiff-node-status n)) result)))
    (nreverse result)))

(defmacro dirdiff-test--in-buffer (session &rest body)
  "Run BODY in a dirdiff buffer showing SESSION, answering yes to prompts."
  (declare (indent 1))
  `(let ((buffer (dirdiff-show-session ,session)))
     (unwind-protect
         (with-current-buffer buffer
           (cl-letf (((symbol-function 'y-or-n-p) #'always)
                     ((symbol-function 'yes-or-no-p) #'always))
             ,@body))
       (kill-buffer buffer))))

(defun dirdiff-test--lines ()
  "The buffer text as a list of lines with runs of spaces collapsed."
  (mapcar (lambda (l) (string-trim (replace-regexp-in-string " +" " " l)))
          (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n" t)))

(defun dirdiff-test--read (file)
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
      (should (eq (dirdiff-test--status s "other-size.bin") 'changed))
      (should (dirdiff-node-binary (dirdiff-test--find s "identical.bin"))))
    (let ((s (dirdiff-test--session left right :binary-comparison 'full)))
      (should (eq (dirdiff-test--status s "same-size.bin") 'changed))
      (should (eq (dirdiff-test--status s "identical.bin") 'same)))
    ;; Different times: quick reports a difference.
    (set-file-times (expand-file-name "identical.bin" right) (current-time))
    (should (eq (dirdiff-test--status
                 (dirdiff-test--session left right :binary-comparison 'quick) "identical.bin")
                'changed))))

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
  (dirdiff--goto-node (dirdiff-test--find dirdiff--session rel)))

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
      (should (equal (directory-files (expand-file-name "d" right) nil "^[^.]") '("a" "b")))
      (should (eq (dirdiff-test--status dirdiff--session "d") 'same)))))

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

(ert-deftest dirdiff-test-copy-nothing ()
  (dirdiff-test--with-dirs '() '(("r" . "r"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (dirdiff-test--goto "r")
      (should-error (dirdiff-copy-to-right) :type 'user-error))))

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
           (file (dirdiff--local-file-in s "a.txt" 'left)))
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

(defun dirdiff--local-file-in (session rel side)
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

(ert-deftest dirdiff-test-git-parse-range ()
  (dirdiff-test--with-repo
    (should (equal (dirdiff-git--parse-range "A..B") '("A" "B")))
    (should (equal (dirdiff-git--parse-range "A..") '("A" "HEAD")))
    (should (equal (dirdiff-git--parse-range "..B") '("HEAD" "B")))
    (should (equal (dirdiff-git--parse-range "HEAD~1") '("HEAD~1" nil)))
    (should (equal (dirdiff-git--parse-range "") '("HEAD" nil)))
    (should (equal (dirdiff-git--parse-range "HEAD^!")
                   (list (string-trim (dirdiff-git--run repo "rev-parse" "HEAD~1")) "HEAD")))
    (should (equal (dirdiff-git--parse-range "HEAD~1^!")
                   (list dirdiff-git--empty-tree "HEAD~1")))
    (should (equal (dirdiff-git--parse-range "HEAD~1...HEAD")
                   (list (string-trim (dirdiff-git--run repo "rev-parse" "HEAD~1")) "HEAD")))))

(provide 'dirdiff-test)
;;; dirdiff-test.el ends here
