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
  "Move to the row of the node at REL, expanding directories as needed."
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
      (should (equal (directory-files (expand-file-name "d" right) nil "\\`[^.]") '("a" "b")))
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
                       '("The current file will be moved to the trash.  Replace f on the right side? "
                         "The current file will be deleted permanently.  Replace f on the right side? "
                         "Copy g to the right side? ")))
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
(ert-deftest dirdiff-test-open-links ()
  (dirdiff-test--with-dirs '(("d/x" . "x") ("l" link . "d")) '(("e/x" . "x") ("l" link . "e"))
    (dirdiff-test--in-buffer (dirdiff-test--session left right)
      (dirdiff-test--goto "l")
      (should (equal (dirdiff-test--messages #'dirdiff-open)
                     '("Symbolic links are different"))))))

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
;; ran an ediff that found no differences.
(ert-deftest dirdiff-test-git-mode-only-change ()
  (dirdiff-test--with-repo
    (set-file-modes (expand-file-name "same.txt" repo) #o755)
    (dirdiff-test--in-buffer (dirdiff-test--git-session repo "HEAD" nil)
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

;; Bug: magit's `D p' suggested a range, often a useless one, instead
;; of comparing a commit with its previous commit.
(ert-deftest dirdiff-test-git-previous ()
  (dirdiff-test--with-repo
    (let ((default-directory repo)
          compared)
      (cl-letf (((symbol-function 'dirdiff-git-compare)
                 (lambda (&rest revs) (setq compared revs)))
                ((symbol-function 'completing-read)
                 (lambda (_prompt _choices &rest args) (nth 4 args))))
        (call-interactively #'dirdiff-git-previous)
        (should (equal compared '("HEAD^" "HEAD")))
        (dirdiff-git-previous "HEAD~1")
        (should (equal compared (list dirdiff-git--empty-tree "HEAD~1")))
        (dirdiff-git-previous "HEAD~1" "HEAD")
        (should (equal compared (list dirdiff-git--empty-tree "HEAD")))))))

(ert-deftest dirdiff-test-magit-setup ()
  "The keys replace existing suffixes, also when set up twice."
  (skip-unless (require 'magit-diff nil t))
  (transient-append-suffix 'magit-diff '(-1 -1 -1) '("D p" "Difftool" ignore))
  (dirdiff-magit-setup)
  (dirdiff-magit-setup)
  (let ((layout (format "%S" (get 'magit-diff 'transient--layout))))
    (pcase-dolist (`(,key . ,command) '(("D p" . dirdiff-git-previous)
                                         ("D h" . dirdiff-git-against-head)
                                         ("D w" . dirdiff-git-against-worktree)
                                         ("D r" . dirdiff-git)))
      (should (eq (plist-get (cdr (transient-get-suffix 'magit-diff key)) :command) command))
      (should (= 1 (with-temp-buffer
                     (insert layout)
                     (how-many (regexp-quote (format ":key %S" key)) (point-min))))))))

(provide 'dirdiff-test)
;;; dirdiff-test.el ends here
