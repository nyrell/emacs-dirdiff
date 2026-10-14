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
;;
;;   M-x dirdiff-git            like `git difftool -d RANGE'
;;   M-x dirdiff-git-commit     a commit against its parent
;;   M-x dirdiff-git-head       a revision against HEAD
;;   M-x dirdiff-git-worktree   a revision against the working tree
;;   M-x dirdiff-git-status     HEAD against the working tree
;;
;; `dirdiff-magit-setup' adds these to magit's diff menu and
;; `dirdiff-vc-setup' adds a key to vc's log view.

;;; Code:

(require 'dirdiff)

(declare-function magit-diff-read-range-or-commit "magit-diff")
(declare-function magit-read-branch-or-commit "magit-git")
(declare-function log-view-current-tag "log-view")
(defvar log-view-mode-map)

(defcustom dirdiff-git-hide-identical t
  "Non-nil means git comparisons initially hide identical entries.
That makes them look like `git difftool --dir-diff'; toggle with
\\<dirdiff-mode-map>\\[dirdiff-toggle-hide-identical] to see the whole tree."
  :type 'boolean
  :group 'dirdiff)

(defconst dirdiff-git--empty-tree "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  "The id of git's empty tree, used as the parent of a root commit.")

(cl-defstruct (dirdiff-git-source (:include dirdiff-source)
                                  (:constructor dirdiff-git-source-create)
                                  (:copier nil))
  "A git revision, or the working tree when REV is nil."
  repo rev table tmpdir
  untracked)  ; working tree: hash table of untracked paths

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
              (error "git %s failed: %s" (string-join args " ")
                     (string-trim (with-temp-buffer
                                    (insert-file-contents stderr)
                                    (buffer-string)))))
            (buffer-string)))
      (delete-file stderr))))

(defun dirdiff-git--blob (repo id)
  "Return the contents of blob ID in REPO as a unibyte string."
  (let ((default-directory (file-name-as-directory repo))
        (coding-system-for-read 'no-conversion))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (unless (eql 0 (process-file "git" nil t nil "cat-file" "blob" id))
        (error "git cat-file blob %s failed" id))
      (buffer-string))))

(defun dirdiff-git--write-blob (repo id file)
  (let ((contents (dirdiff-git--blob repo id))
        (coding-system-for-write 'no-conversion))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (insert contents))))

(defun dirdiff-git--toplevel (&optional directory)
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

;;;; Listing trees

(defun dirdiff-git--add (table path entry &optional root)
  "Add ENTRY at PATH to TABLE, creating parent directory entries.
TABLE maps a directory's relative name to a hash table of its entries.
ROOT is the working tree, for the file names of directory entries."
  (let ((dir "")
        (parts (split-string path "/")))
    (while (cdr parts)
      (let ((name (pop parts)))
        (unless (gethash name (gethash dir table))
          (puthash name (dirdiff-entry-create
                         :type 'dir
                         :file (and root (expand-file-name (dirdiff--join dir name) root)))
                   (gethash dir table)))
        (setq dir (dirdiff--join dir name))
        (unless (gethash dir table)
          (puthash dir (make-hash-table :test #'equal) table))))
    (puthash (car parts) entry (gethash dir table))))

(defun dirdiff-git--load (source)
  "List the tree of SOURCE.  Revisions are listed once, the working tree always."
  (unless (and (dirdiff-git-source-table source) (dirdiff-git-source-rev source))
    (let ((repo (dirdiff-git-source-repo source))
          (rev (dirdiff-git-source-rev source))
          (table (make-hash-table :test #'equal)))
      (puthash "" (make-hash-table :test #'equal) table)
      (if rev
          (dolist (record (split-string (dirdiff-git--run repo "ls-tree" "-r" "-z" "--long"
                                                          "--full-tree" rev)
                                        "\0" t))
            (when (string-match "\\`\\([0-7]+\\) \\([a-z]+\\) \\([0-9a-f]+\\) +\\([0-9]+\\|-\\)\t\\(\\(?:.\\|\n\\)*\\)\\'"
                                record)
              (let ((mode (match-string 1 record))
                    (type (match-string 2 record))
                    (size (match-string 4 record)))
                (dirdiff-git--add table (match-string 5 record)
                                  (dirdiff-entry-create
                                   :type (cond ((equal type "commit") 'module)
                                               ((equal mode "120000") 'link)
                                               (t 'file))
                                   :id (match-string 3 record)
                                   :mode mode
                                   :size (and (not (equal size "-")) (string-to-number size)))))))
        (let ((untracked (make-hash-table :test #'equal)))
          (dolist (path (split-string (dirdiff-git--run repo "ls-files" "-z" "--others"
                                                        "--exclude-standard")
                                      "\0" t))
            (puthash path t untracked))
          (setf (dirdiff-git-source-untracked source) untracked))
        (dolist (path (delete-dups
                       (nconc (split-string (dirdiff-git--run repo "ls-files" "-z" "--cached")
                                            "\0" t)
                              (hash-table-keys (dirdiff-git-source-untracked source)))))
          (let* ((file (expand-file-name path repo))
                 (attrs (file-attributes file)))
            ;; Tracked files deleted from the working tree are left out.
            (when attrs
              (let ((entry (dirdiff--fs-entry file attrs)))
                ;; A directory listed by ls-files is a submodule.
                (when (eq (dirdiff-entry-type entry) 'dir)
                  (setf (dirdiff-entry-type entry) 'module))
                (dirdiff-git--add table path entry repo))))))
      (setf (dirdiff-git-source-table source) table))))

(cl-defmethod dirdiff-source-children ((source dirdiff-git-source) rel)
  (let (result)
    (when-let* ((entries (gethash rel (dirdiff-git-source-table source))))
      (maphash (lambda (name entry) (push (cons name entry) result)) entries))
    result))

;;;; File access

(defun dirdiff-git--tmpdir (source)
  (with-memoization (dirdiff-git-source-tmpdir source)
    (make-temp-file (format "dirdiff-%s-"
                            (substring (dirdiff-git-source-rev source) 0 7))
                    t)))

(cl-defmethod dirdiff-source-file ((source dirdiff-git-source) entry rel)
  (if (not (dirdiff-git-source-rev source))
      (dirdiff-entry-file entry)
    (let ((file (expand-file-name rel (dirdiff-git--tmpdir source))))
      (unless (file-exists-p file)
        (make-directory (file-name-directory file) t)
        (dirdiff-git--write-blob (dirdiff-git-source-repo source) (dirdiff-entry-id entry) file)
        (set-file-modes file #o444))
      file)))

(cl-defmethod dirdiff-source-cleanup ((source dirdiff-git-source))
  (when-let* ((dir (dirdiff-git-source-tmpdir source)))
    (setf (dirdiff-git-source-tmpdir source) nil)
    (delete-directory dir t)))

(cl-defmethod dirdiff-source-path ((source dirdiff-git-source) rel)
  (and (not (dirdiff-git-source-rev source))
       (expand-file-name rel (dirdiff-git-source-repo source))))

(cl-defmethod dirdiff-source-copy-to ((source dirdiff-git-source) entry rel dest)
  (if (not (dirdiff-git-source-rev source))
      (cl-call-next-method)
    (let ((repo (dirdiff-git-source-repo source)))
      (pcase (dirdiff-entry-type entry)
        ('dir
         (make-directory dest t)
         (pcase-dolist (`(,name . ,child) (dirdiff-source-children source rel))
           (dirdiff-source-copy-to source child (dirdiff--join rel name)
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
           (set-file-modes dest #o755)))))))

;;;; Status

(defun dirdiff-git--changed-paths (repo revs)
  "Return a hash table of the paths that differ between REVS in REPO.
REVS is (REV) to compare with the working tree, or (REV1 REV2)."
  (let ((changed (make-hash-table :test #'equal))
        (fields (split-string (apply #'dirdiff-git--run repo "diff" "--raw" "-z"
                                     "--no-renames" "--no-ext-diff" revs)
                              "\0" t)))
    ;; With -z, each record is ":<modes> <ids> <status>" NUL "<path>".
    (while fields
      (let ((meta (pop fields)) (path (pop fields)))
        (when (string-prefix-p ":" meta)
          (puthash path t changed))))
    (when dirdiff-ignore-whitespace
      ;; `--numstat -w' leaves out files whose changes are all whitespace.
      (let ((real (make-hash-table :test #'equal)))
        (dolist (record (split-string (apply #'dirdiff-git--run repo "diff" "--numstat" "-z" "-w"
                                             "--no-renames" "--no-ext-diff" revs)
                                      "\0" t))
          (when (string-match "\\`[0-9-]+\t[0-9-]+\t\\(\\(?:.\\|\n\\)*\\)\\'" record)
            (puthash (match-string 1 record) t real)))
        (maphash (lambda (path _) (unless (gethash path real) (remhash path changed)))
                 changed)))
    changed))

(defun dirdiff-git--prepare (session)
  "List both sides of SESSION and find out which files differ."
  (let* ((left (dirdiff-session-left session))
         (right (dirdiff-session-right session))
         (repo (dirdiff-git-source-repo left))
         (revs (delq nil (list (dirdiff-git-source-rev left)
                               (dirdiff-git-source-rev right)))))
    (unless (dirdiff-git-source-rev right)
      ;; Make sure files that were only touched are not reported as changed.
      (ignore-errors (dirdiff-git--run repo "update-index" "-q" "--refresh")))
    (dirdiff-git--load left)
    (dirdiff-git--load right)
    (let ((changed (dirdiff-git--changed-paths repo revs))
          (untracked (or (dirdiff-git-source-untracked right) #s(hash-table))))
      ;; git diff knows nothing about untracked files; those are compared
      ;; by content instead (returning nil falls back to that).
      (setf (dirdiff-session-oracle session)
            (lambda (_session node)
              (let ((rel (dirdiff-node-rel node)))
                (cond ((gethash rel untracked) nil)
                      ((gethash rel changed) 'changed)
                      (t 'same))))))))

;;;; Entry points

(defun dirdiff-git--source (repo rev)
  (if (not rev)
      (dirdiff-git-source-create :repo repo :label "Working tree" :writable t)
    (let ((id (dirdiff-git--resolve repo rev)))
      (dirdiff-git-source-create
       :repo repo :rev id :writable nil
       :label (cond ((equal id dirdiff-git--empty-tree) "(empty)")
                    ((string-prefix-p rev id) (substring id 0 (max 7 (length rev))))
                    (t (format "%s (%s)" rev (substring id 0 7))))))))

;;;###autoload
(defun dirdiff-git-compare (left-rev right-rev &optional directory)
  "Compare LEFT-REV with RIGHT-REV in the git repository of DIRECTORY.
RIGHT-REV nil means the working tree.  DIRECTORY defaults to
`default-directory'."
  (let* ((repo (dirdiff-git--toplevel directory))
         (left (dirdiff-git--source repo left-rev))
         (right (dirdiff-git--source repo right-rev)))
    (dirdiff-show-session
     (dirdiff-session-create
      :left left :right right
      :prepare #'dirdiff-git--prepare
      :use-ignored-names nil
      :hide-identical dirdiff-git-hide-identical)
     (format "*dirdiff %s: %s ↔ %s*"
             (file-name-nondirectory (directory-file-name repo))
             (dirdiff-source-label left) (dirdiff-source-label right)))))

(defun dirdiff-git--refs ()
  (ignore-errors
    (cons "HEAD" (split-string (dirdiff-git--run default-directory "for-each-ref"
                                                 "--format=%(refname:short)")
                               "\n" t))))

(defun dirdiff-git--read-rev (prompt &optional default)
  (if (fboundp 'magit-read-branch-or-commit)
      (magit-read-branch-or-commit prompt default)
    (let ((default (or default "HEAD")))
      (completing-read (format-prompt prompt default) (dirdiff-git--refs)
                       nil nil nil nil default))))

(defun dirdiff-git--read-range ()
  (if (fboundp 'magit-diff-read-range-or-commit)
      (magit-diff-read-range-or-commit "Dirdiff range or commit")
    (completing-read "Dirdiff range or revision (empty: HEAD vs working tree): "
                     (dirdiff-git--refs))))

(defun dirdiff-git--parse-range (range)
  "Turn RANGE into (LEFT-REV RIGHT-REV) the way `git difftool -d' does.
A single revision is compared with the working tree; empty means HEAD."
  (let ((range (string-trim range)))
    (cond
     ((string-match "\\`\\(.*?\\)\\.\\.\\.\\(.*\\)\\'" range)
      (let ((a (if (string-empty-p (match-string 1 range)) "HEAD" (match-string 1 range)))
            (b (if (string-empty-p (match-string 2 range)) "HEAD" (match-string 2 range))))
        (list (string-trim (dirdiff-git--run default-directory "merge-base" a b)) b)))
     ((string-match "\\`\\(.*?\\)\\.\\.\\(.*\\)\\'" range)
      (list (if (string-empty-p (match-string 1 range)) "HEAD" (match-string 1 range))
            (if (string-empty-p (match-string 2 range)) "HEAD" (match-string 2 range))))
     ((string-empty-p range) (list "HEAD" nil))
     (t (list range nil)))))

;;;###autoload
(defun dirdiff-git (range)
  "Compare git revisions like `git difftool --dir-diff RANGE'.
RANGE is \"A..B\" (A with B), \"A...B\" (the merge base of A and B
with B) or a single revision (compared with the working tree).  An
empty RANGE compares HEAD with the working tree."
  (interactive (list (dirdiff-git--read-range)))
  (apply #'dirdiff-git-compare (dirdiff-git--parse-range range)))

;;;###autoload
(defun dirdiff-git-commit (rev)
  "Compare commit REV with its (first) parent."
  (interactive (list (dirdiff-git--read-rev "Commit")))
  (let ((parent (condition-case nil
                    (string-trim (dirdiff-git--run default-directory "rev-parse"
                                                   "--verify" "--quiet" (concat rev "^")))
                  (error dirdiff-git--empty-tree))))
    (dirdiff-git-compare parent rev)))

;;;###autoload
(defun dirdiff-git-head (rev)
  "Compare revision REV with HEAD."
  (interactive (list (dirdiff-git--read-rev "Compare with HEAD")))
  (dirdiff-git-compare rev "HEAD"))

;;;###autoload
(defun dirdiff-git-worktree (rev)
  "Compare revision REV with the working tree."
  (interactive (list (dirdiff-git--read-rev "Compare with working tree")))
  (dirdiff-git-compare rev nil))

;;;###autoload
(defun dirdiff-git-status ()
  "Compare HEAD with the working tree."
  (interactive)
  (dirdiff-git-compare "HEAD" nil))

;;;; Magit and vc integration

;;;###autoload
(defun dirdiff-magit-setup ()
  "Add dirdiff commands to magit's diff menu (\\`d' in magit buffers).
They are bound to \\`D p' (range or commit), \\`D h' (against HEAD)
and \\`D w' (against the working tree)."
  (with-eval-after-load 'magit-diff
    (transient-append-suffix 'magit-diff '(-1 -1 -1)
      '("D p" "Dirdiff range or commit" dirdiff-git))
    (transient-append-suffix 'magit-diff '(-1 -1 -1)
      '("D h" "Dirdiff against HEAD" dirdiff-git-head))
    (transient-append-suffix 'magit-diff '(-1 -1 -1)
      '("D w" "Dirdiff against working tree" dirdiff-git-worktree))))

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
    (dirdiff-git-commit (or (log-view-current-tag) (user-error "No revision at point")))))

;;;###autoload
(defun dirdiff-vc-setup ()
  "Bind \\`D' in vc log buffers to `dirdiff-git-log-view'."
  (with-eval-after-load 'log-view
    (keymap-set log-view-mode-map "D" #'dirdiff-git-log-view)))

(provide 'dirdiff-git)
;;; dirdiff-git.el ends here
