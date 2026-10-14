;;; dirdiff-git.el --- Compare git revisions with dirdiff  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Mattias Nyrell

;; Author: Mattias Nyrell <mattias@nyrell.se>

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Compare two git revisions, or a revision and the working tree, in a
;; dirdiff buffer.  Nothing is checked out: both trees are listed with
;; `git ls-tree' / `git ls-files', and which files differ comes from
;; `git diff --raw', so even huge repositories compare quickly.  File
;; contents are extracted with `git cat-file' only when a file is
;; opened, copied or diffed.
;;
;; Sides that are revisions are read-only; the working tree is editable.
;; The working tree is an ordinary directory side, restricted to the
;; files git knows about (tracked, or untracked and not ignored).
;;
;;   M-x dirdiff-git                    like `git difftool -d RANGE':
;;                                      A..B, A...B, C^! or A
;;   M-x dirdiff-git-against-head       a revision vs HEAD
;;   M-x dirdiff-git-against-worktree   a revision vs the working tree
;;
;; `dirdiff-magit-setup' adds these to magit's diff menu and
;; `dirdiff-vc-setup' adds a key to vc's log view.

;;; Code:

(require 'dirdiff)

(declare-function magit-diff-read-range-or-commit "ext:magit-diff")
(declare-function magit-read-branch-or-commit "ext:magit-git")
(declare-function log-view-current-tag "log-view")
(defvar log-view-mode-map)

(defconst dirdiff-git--empty-tree "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  "The id of git's empty tree, used as the parent of a root commit.")

(cl-defstruct (dirdiff-git-source (:include dirdiff-source)
                                  (:constructor dirdiff-git-source-create)
                                  (:copier nil))
  "A git revision."
  repo rev
  table    ; directory rel -> hash table of name -> entry
  tmpdir)  ; where file contents are extracted to

;;;; Running git

(defun dirdiff-git--run (repo &rest args)
  "Run git with ARGS in REPO and return its output as a string."
  (let ((default-directory (file-name-as-directory repo))
        (stderr (make-temp-file "dirdiff-git-err")))
    (unwind-protect
        (with-temp-buffer
          (let* ((coding-system-for-read 'utf-8)
                 (status (apply #'process-file "git" nil (list t stderr) nil args)))
            (unless (eql status 0)
              (error "Running git %s failed: %s" (string-join args " ")
                     (string-trim (with-temp-buffer
                                    (insert-file-contents stderr)
                                    (buffer-string)))))
            (buffer-string)))
      (delete-file stderr))))

(defun dirdiff-git--lines (repo &rest args)
  "Run git with ARGS in REPO; return its NUL-separated output as a list."
  (split-string (apply #'dirdiff-git--run repo args) "\0" t))

(defun dirdiff-git--blob (repo id)
  "Return the contents of blob ID in REPO as a unibyte string."
  (let ((default-directory (file-name-as-directory repo))
        (coding-system-for-read 'no-conversion))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (unless (eql 0 (process-file "git" nil t nil "cat-file" "blob" id))
        (error "Reading git blob %s failed" id))
      (buffer-string))))

(defun dirdiff-git--write-blob (repo id file)
  "Write blob ID of REPO to FILE."
  (let ((contents (dirdiff-git--blob repo id))
        (coding-system-for-write 'no-conversion))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (insert contents))))

(defun dirdiff-git--toplevel (&optional directory)
  "Return the top directory of the git repository containing DIRECTORY."
  (let ((default-directory (or directory default-directory)))
    (file-name-as-directory
     (expand-file-name
      (string-trim (condition-case nil
                       (dirdiff-git--run default-directory "rev-parse" "--show-toplevel")
                     (error (user-error "Not inside a git repository: %s"
                                        default-directory))))))))

(defun dirdiff-git--resolve (repo rev)
  "Return the full commit id of REV in REPO, or signal an error."
  (if (equal rev dirdiff-git--empty-tree)
      rev
    (condition-case nil
        (string-trim (dirdiff-git--run repo "rev-parse" "--verify" "--quiet"
                                       (concat rev "^{commit}")))
      (error (user-error "Unknown revision: %s" rev)))))

;;;; Revisions

(defun dirdiff-git--load (source)
  "List the tree of revision SOURCE, once."
  (unless (dirdiff-git-source-table source)
    (let ((table (make-hash-table :test #'equal)))
      (puthash "" (make-hash-table :test #'equal) table)
      (dolist (record (dirdiff-git--lines (dirdiff-git-source-repo source)
                                          "ls-tree" "-r" "-z" "--long" "--full-tree"
                                          (dirdiff-git-source-rev source)))
        (when (string-match "\\`\\([0-7]+\\) \\([a-z]+\\) \\([0-9a-f]+\\) +\\([0-9]+\\|-\\)\t\\(\\(?:.\\|\n\\)*\\)\\'"
                            record)
          (let* ((mode (match-string 1 record))
                 (size (match-string 4 record))
                 (entry (dirdiff-entry-create
                         :type (cond ((equal (match-string 2 record) "commit") 'module)
                                     ((equal mode "120000") 'link)
                                     (t 'file))
                         :id (match-string 3 record)
                         :mode mode
                         :size (and (not (equal size "-")) (string-to-number size))))
                 (dir "")
                 (parts (split-string (match-string 5 record) "/")))
            ;; Create the entries of the parent directories on the way.
            (while (cdr parts)
              (let ((name (pop parts)))
                (unless (gethash name (gethash dir table))
                  (puthash name (dirdiff-entry-create :type 'dir) (gethash dir table)))
                (setq dir (file-name-concat dir name))
                (unless (gethash dir table)
                  (puthash dir (make-hash-table :test #'equal) table))))
            (puthash (car parts) entry (gethash dir table)))))
      (setf (dirdiff-git-source-table source) table))))

(cl-defmethod dirdiff-source-children ((source dirdiff-git-source) rel)
  "List directory REL of revision SOURCE."
  (let (result)
    (when-let* ((entries (gethash rel (dirdiff-git-source-table source))))
      (maphash (lambda (name entry) (push (cons name entry) result)) entries))
    result))

(cl-defmethod dirdiff-source-file ((source dirdiff-git-source) entry rel)
  "Extract ENTRY at REL of SOURCE to a read-only temporary file."
  (let ((file (expand-file-name
               rel (with-memoization (dirdiff-git-source-tmpdir source)
                     (make-temp-file (format "dirdiff-%s-"
                                             (substring (dirdiff-git-source-rev source) 0 7))
                                     t)))))
    (unless (file-exists-p file)
      (make-directory (file-name-directory file) t)
      (dirdiff-git--write-blob (dirdiff-git-source-repo source) (dirdiff-entry-id entry) file)
      (set-file-modes file #o444))
    file))

(cl-defmethod dirdiff-source-copy-to ((source dirdiff-git-source) entry rel dest)
  "Write ENTRY at REL of revision SOURCE to DEST, recursively."
  (let ((repo (dirdiff-git-source-repo source)))
    (pcase (dirdiff-entry-type entry)
      ('dir
       (make-directory dest t)
       (pcase-dolist (`(,name . ,child) (dirdiff-source-children source rel))
         (dirdiff-source-copy-to source child (file-name-concat rel name)
                                 (expand-file-name name dest))))
      ('link
       (make-symbolic-link (decode-coding-string
                            (dirdiff-git--blob repo (dirdiff-entry-id entry)) 'utf-8)
                           dest t))
      ('module
       (make-directory dest t)
       (message "Submodule %s: only the directory was created" rel))
      (_
       (dirdiff-git--write-blob repo (dirdiff-entry-id entry) dest)
       (when (equal (dirdiff-entry-mode entry) "100755")
         (set-file-modes dest #o755))))))

;;;; Comparing

(defun dirdiff-git--list-worktree (repo)
  "List the files of REPO's working tree that git knows about.
Return (ONLY . UNTRACKED): ONLY maps relative names to `file' or
`dir' (see `dirdiff-dir-source'), UNTRACKED holds untracked files."
  ;; Make sure files that were only touched are not reported as changed.
  (ignore-errors (dirdiff-git--run repo "update-index" "-q" "--refresh"))
  (let ((only (make-hash-table :test #'equal))
        (untracked (make-hash-table :test #'equal)))
    (dolist (path (dirdiff-git--lines repo "ls-files" "-z" "--others" "--exclude-standard"))
      (puthash path t untracked))
    (dolist (path (nconc (dirdiff-git--lines repo "ls-files" "-z" "--cached")
                         (hash-table-keys untracked)))
      (puthash path 'file only)
      (let ((dir (file-name-directory path)))
        (while dir
          (setq dir (directory-file-name dir))
          (unless (gethash dir only) (puthash dir 'dir only))
          (setq dir (file-name-directory dir)))))
    (cons only untracked)))

(defun dirdiff-git--changed-paths (repo revs ignore-whitespace)
  "Return a hash table of the paths that differ between REVS in REPO.
REVS is (REV) to compare with the working tree, or (REV1 REV2).
With IGNORE-WHITESPACE, leave out files whose changes are all whitespace."
  (let ((changed (make-hash-table :test #'equal))
        (fields (apply #'dirdiff-git--lines repo "diff" "--raw" "-z"
                       "--no-renames" "--no-ext-diff" revs)))
    ;; With -z, each record is ":<modes> <ids> <status>" NUL "<path>".
    (while fields
      (let ((meta (pop fields)) (path (pop fields)))
        (when (string-prefix-p ":" meta)
          (puthash path t changed))))
    (when ignore-whitespace
      ;; `--numstat -w' leaves out files whose changes are all whitespace.
      (let ((real (make-hash-table :test #'equal)))
        (dolist (record (apply #'dirdiff-git--lines repo "diff" "--numstat" "-z" "-w"
                               "--no-renames" "--no-ext-diff" revs))
          (when (string-match "\\`[0-9-]+\t[0-9-]+\t\\(\\(?:.\\|\n\\)*\\)\\'" record)
            (puthash (match-string 1 record) t real)))
        (maphash (lambda (path _) (unless (gethash path real) (remhash path changed)))
                 changed)))
    changed))

(defun dirdiff-git--prepare (session)
  "List both sides of SESSION and return a function giving a node's status."
  (let* ((left (dirdiff-session-left session))
         (right (dirdiff-session-right session))
         (repo (dirdiff-git-source-repo left))
         (worktree (dirdiff-dir-source-p right))
         (untracked nil))
    (dirdiff-git--load left)
    (if (not worktree)
        (dirdiff-git--load right)
      (let ((lists (dirdiff-git--list-worktree repo)))
        (setf (dirdiff-dir-source-only right) (car lists))
        (setq untracked (cdr lists))))
    (let ((changed (dirdiff-git--changed-paths
                    repo
                    (cons (dirdiff-git-source-rev left)
                          (and (not worktree) (list (dirdiff-git-source-rev right))))
                    (dirdiff-session-ignore-whitespace session))))
      ;; git diff knows nothing about untracked files; returning nil
      ;; makes dirdiff compare those by content.
      (lambda (node)
        (let ((rel (dirdiff-node-rel node)))
          (cond ((and untracked (gethash rel untracked)) nil)
                ((gethash rel changed) 'changed)
                (t 'same)))))))

;;;; Entry points

(defun dirdiff-git--source (repo rev)
  "Return a source for revision REV of REPO."
  (let ((id (dirdiff-git--resolve repo rev)))
    (dirdiff-git-source-create
     :repo repo :rev id :writable nil
     :label (cond ((equal id dirdiff-git--empty-tree) "(empty)")
                  ((string-prefix-p rev id) (substring id 0 (max 7 (length rev))))
                  (t (format "%s (%s)" rev (substring id 0 7)))))))

(defun dirdiff-git--session (repo left-rev right-rev)
  "Return a session comparing LEFT-REV with RIGHT-REV in REPO.
RIGHT-REV nil means the working tree."
  (let ((left (dirdiff-git--source repo left-rev))
        (right (if right-rev
                   (dirdiff-git--source repo right-rev)
                 (dirdiff-dir-source-create :root repo :label "Working tree" :writable t))))
    (dirdiff-session-create
     :left left :right right
     :prepare #'dirdiff-git--prepare
     :hide-identical t
     :cleanup (list (lambda ()
                      (dolist (source (list left right))
                        (when (and (dirdiff-git-source-p source)
                                   (dirdiff-git-source-tmpdir source))
                          (delete-directory (dirdiff-git-source-tmpdir source) t))))))))

(defun dirdiff-git-compare (left-rev right-rev &optional directory)
  "Compare LEFT-REV with RIGHT-REV in the git repository of DIRECTORY.
RIGHT-REV nil means the working tree.  DIRECTORY defaults to
`default-directory'."
  (let* ((repo (dirdiff-git--toplevel directory))
         (session (dirdiff-git--session repo left-rev right-rev)))
    (dirdiff-show-session
     session
     (format "*dirdiff %s: %s ↔ %s*"
             (file-name-nondirectory (directory-file-name repo))
             (dirdiff-source-label (dirdiff-session-left session))
             (dirdiff-source-label (dirdiff-session-right session))))))

(defun dirdiff-git--parse-range (range)
  "Turn RANGE into (LEFT-REV RIGHT-REV) the way `git difftool -d' does.
\"A..B\" and \"A...B\" (merge base of A and B) compare with B, \"C^!\"
compares commit C with its parent, a single revision is compared with
the working tree (RIGHT-REV nil), and empty means HEAD."
  (let ((range (string-trim range)))
    (cl-flet ((or-head (s) (if (string-empty-p s) "HEAD" s)))
      (cond
       ((string-match "\\`\\(.*?\\)\\.\\.\\.\\(.*\\)\\'" range)
        (let ((a (or-head (match-string 1 range)))
              (b (or-head (match-string 2 range))))
          (list (string-trim (dirdiff-git--run default-directory "merge-base" a b)) b)))
       ((string-match "\\`\\(.*?\\)\\.\\.\\(.*\\)\\'" range)
        (list (or-head (match-string 1 range)) (or-head (match-string 2 range))))
       ((string-match "\\`\\(.+\\)\\^!\\'" range)
        (let ((commit (match-string 1 range)))
          (list (dirdiff-git--parent commit) commit)))
       (t (list (or-head range) nil))))))

(defun dirdiff-git--parent (commit)
  "Return COMMIT^, or the empty tree if COMMIT has no parent."
  (condition-case nil
      (progn (dirdiff-git--run default-directory "rev-parse" "--verify" "--quiet"
                               (concat commit "^"))
             (concat commit "^"))
    (error dirdiff-git--empty-tree)))

(defun dirdiff-git--read-rev (prompt)
  "Read a revision with PROMPT, with magit's reader if available.
The default is the branch or commit at point, else the current branch."
  (if (fboundp 'magit-read-branch-or-commit)
      (magit-read-branch-or-commit prompt)
    (completing-read (format-prompt prompt "HEAD")
                     (ignore-errors
                       (cons "HEAD" (split-string (dirdiff-git--run default-directory
                                                                    "for-each-ref"
                                                                    "--format=%(refname:short)")
                                                  "\n" t)))
                     nil nil nil nil "HEAD")))

;;;###autoload
(defun dirdiff-git (range)
  "Compare git revisions like `git difftool --dir-diff RANGE'.
RANGE is \"A..B\" (A with B), \"A...B\" (the merge base of A and B
with B), \"C^!\" (commit C with its parent) or a single revision
\(compared with the working tree).  Empty compares HEAD with the
working tree.

With magit, the range is read like magit's \\`d r': it suggests
\"C^..C\" for the commit C at point, and commits selected in a log
are used as \"A..B\" (\"A...B\" with a prefix argument)."
  (interactive
   (list (if (fboundp 'magit-diff-read-range-or-commit)
             (magit-diff-read-range-or-commit "Dirdiff range" nil current-prefix-arg)
           (read-string "Dirdiff range or revision (empty: HEAD vs working tree): "))))
  (apply #'dirdiff-git-compare (dirdiff-git--parse-range range)))

;;;; Magit and vc integration

;;;###autoload
(defun dirdiff-git-against-head (rev)
  "Compare REV with HEAD, like `git difftool -d REV..HEAD'."
  (interactive (list (dirdiff-git--read-rev "Compare with HEAD")))
  (dirdiff-git-compare rev "HEAD"))

;;;###autoload
(defun dirdiff-git-against-worktree (rev)
  "Compare REV with the working tree, like `git difftool -d REV'."
  (interactive (list (dirdiff-git--read-rev "Compare with working tree")))
  (dirdiff-git-compare rev nil))

;;;###autoload
(defun dirdiff-magit-setup ()
  "Add dirdiff commands to magit's diff menu (\\`d' in magit buffers).
\\`D p' compares a range (suggesting the commit at point with its
previous one), \\`D h' a revision with HEAD and \\`D w' a revision
with the working tree.  Suffixes already on these keys are replaced.
This loads magit, so call it from `with-eval-after-load' in your init
file."
  (require 'magit-diff)
  (pcase-dolist (`(,key ,description ,command)
                 '(("D p" "Dirdiff with previous" dirdiff-git)
                   ("D h" "Dirdiff with HEAD" dirdiff-git-against-head)
                   ("D w" "Dirdiff with working tree" dirdiff-git-against-worktree)))
    (while (ignore-errors (transient-get-suffix 'magit-diff key))
      (transient-remove-suffix 'magit-diff key))
    (transient-append-suffix 'magit-diff '(-1 -1 -1)
      (list key description command))))

;;;###autoload
(defun dirdiff-git-log-view ()
  "Compare revisions from a vc log buffer.
With an active region, compare the oldest and newest revisions in
it; otherwise compare the revision at point with its parent."
  (interactive)
  (require 'log-view)
  (if (use-region-p)
      (let ((newest (save-excursion (goto-char (region-beginning)) (log-view-current-tag)))
            (oldest (save-excursion (goto-char (max (region-beginning) (1- (region-end))))
                                    (log-view-current-tag))))
        (deactivate-mark)
        (dirdiff-git-compare oldest newest))
    (dirdiff-git (concat (or (log-view-current-tag) (user-error "No revision at point"))
                         "^!"))))

;;;###autoload
(defun dirdiff-vc-setup ()
  "Bind \\`D' in vc log buffers to `dirdiff-git-log-view'.
This loads log-view, so call it from `with-eval-after-load' in your
init file."
  (require 'log-view)
  (keymap-set log-view-mode-map "D" #'dirdiff-git-log-view))

(provide 'dirdiff-git)
;;; dirdiff-git.el ends here
