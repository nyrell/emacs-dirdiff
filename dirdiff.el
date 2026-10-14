;;; dirdiff.el --- Compare directory trees side by side, like Meld  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Mattias Nyrell

;; Author: Mattias Nyrell <mattias@nyrell.se>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: files, tools, vc

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

;; Dirdiff compares two directory trees and shows them side by side in a
;; single buffer: the left tree in the left column and the right tree in
;; the right column, always row-for-row aligned.  Expanding a directory
;; expands it on both sides.  Entries are colored by status: identical,
;; changed, present on one side only, or file-vs-directory conflict.
;;
;; One side is "active" (highlighted); TAB switches side.  RET on a file
;; pair runs `ediff-files', RET on a directory expands or collapses it.
;; Files and directories can be copied to the other side or deleted.
;;
;; Entry points:
;;
;;   M-x dirdiff           compare two files (ediff) or two directories
;;   M-x dirdiff-dired     compare the two directories marked in Dired
;;   M-x dirdiff-git       compare git revisions (see dirdiff-git.el)
;;
;; Press `?' in the dirdiff buffer for a menu of all commands.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'diff-mode)                    ; faces we inherit from
(require 'transient)

(declare-function dired-get-marked-files "dired")
(declare-function dired-marker-regexp "dired")
(declare-function dired-get-filename "dired")
(declare-function dired-dwim-target-directory "dired-aux")
(defvar ediff-diff-options)
(defvar ediff-after-quit-hook-internal)

;;;; Customization

(defgroup dirdiff nil
  "Compare directory trees side by side."
  :group 'tools
  :prefix "dirdiff-")

(defcustom dirdiff-ignored-names '(".git" ".hg" ".svn" ".bzr" "_darcs" "CVS")
  "File and directory names to leave out of the comparison.
Only used while `dirdiff-use-ignored-names' is non-nil."
  :type '(repeat string))

(defcustom dirdiff-use-ignored-names t
  "Non-nil means entries named in `dirdiff-ignored-names' are left out."
  :type 'boolean)

(defcustom dirdiff-ignore-whitespace nil
  "Non-nil means text files differing only in whitespace are identical.
This corresponds to `diff -w'.  It also applies to ediff sessions
started from dirdiff."
  :type 'boolean)

(defcustom dirdiff-binary-comparison 'quick
  "How to compare binary files.
`quick' compares size and modification time only.  `full' compares
the contents byte by byte."
  :type '(choice (const :tag "Size and modification time" quick)
                 (const :tag "Contents, byte by byte" full)))

(defcustom dirdiff-hide-identical nil
  "Non-nil means identical files and directories are hidden initially.
Toggle in the dirdiff buffer with \\<dirdiff-mode-map>\\[dirdiff-toggle-hide-identical]."
  :type 'boolean)

(defcustom dirdiff-initial-expansion 'changed
  "Which directories to expand when a comparison is first shown.
`changed' expands directories present on both sides that contain
differences, `all' expands everything and `none' nothing."
  :type '(choice (const :tag "Directories with differences" changed)
                 (const :tag "All" all)
                 (const :tag "None" none)))

(defcustom dirdiff-large-file-size (* 8 1024 1024)
  "Files larger than this many bytes are compared with external tools.
Below the limit files are compared in Lisp.  Above it `cmp' (or
`diff -w' when ignoring whitespace) is used when available."
  :type 'integer)

(defcustom dirdiff-indicators '("▾ " "▸ " "  ")
  "Strings shown before expanded directories, collapsed ones and files."
  :type '(list (string :tag "Expanded") (string :tag "Collapsed") (string :tag "File")))

;;;; Faces

(defface dirdiff-same '((t :inherit default))
  "Face for entries that are identical on both sides.")

(defface dirdiff-changed '((t :inherit diff-indicator-changed :weight bold))
  "Face for files that differ and directories containing differences.")

(defface dirdiff-new '((t :inherit diff-indicator-added :weight bold))
  "Face for entries present on this side only.")

(defface dirdiff-conflict '((t :inherit diff-indicator-removed :weight bold))
  "Face for entries that are a file on one side and a directory on the other.")

(defface dirdiff-absent '((t :inherit shadow :slant italic))
  "Face for the placeholder of an entry missing on this side.")

(defface dirdiff-active-cell '((t :inherit region :extend nil))
  "Face for the active side of the current row.")

(defface dirdiff-header '((t :inherit shadow))
  "Face for the label of the inactive side in the header line.")

(defface dirdiff-header-active '((t :weight bold))
  "Face for the label of the active side in the header line.")

;;;; Data model

(cl-defstruct (dirdiff-entry (:constructor dirdiff-entry-create)
                             (:copier nil))
  "One side of a node: what exists at that path in one tree."
  type   ; `file', `dir', `link' (symlink not followed) or `module'
  file   ; local file name, or nil when not on disk (git revision)
  size mtime
  id     ; git object id, when known
  mode)  ; git file mode string, when known

(cl-defstruct (dirdiff-node (:constructor dirdiff-node-create)
                            (:copier nil))
  "A row in the comparison: a relative path and both sides of it."
  name rel parent left right status children binary)
;; STATUS is `same', `changed', `left' (left only), `right' (right
;; only) or `conflict' (file on one side, directory on the other).

(cl-defstruct (dirdiff-source (:constructor nil) (:copier nil))
  "Where one side of the comparison comes from."
  label writable)

(cl-defstruct (dirdiff-dir-source (:include dirdiff-source)
                                  (:constructor dirdiff-dir-source-create)
                                  (:copier nil))
  "A directory on disk."
  root)

(cl-defstruct (dirdiff-session (:constructor dirdiff-session-create)
                               (:copier nil))
  left right                            ; sources
  tree                                  ; root node
  (open (make-hash-table :test #'equal)) ; rel -> t for expanded dirs
  prepare     ; function called with the session before (re)building
  oracle      ; function (SESSION NODE) -> `same', `changed' or nil
  cleanup     ; list of functions run when the buffer is killed
  counts      ; cached result of `dirdiff--count-differences'
  (ignore-whitespace dirdiff-ignore-whitespace)
  (binary-comparison dirdiff-binary-comparison)
  (use-ignored-names dirdiff-use-ignored-names)
  (hide-identical dirdiff-hide-identical))

(defmacro dirdiff--with-options (session &rest body)
  "Run BODY with the comparison options of SESSION in effect."
  (declare (indent 1) (debug t))
  (let ((s (make-symbol "session")))
    `(let* ((,s ,session)
            (dirdiff-ignore-whitespace (dirdiff-session-ignore-whitespace ,s))
            (dirdiff-binary-comparison (dirdiff-session-binary-comparison ,s))
            (dirdiff-use-ignored-names (dirdiff-session-use-ignored-names ,s)))
       ,@body)))

(defun dirdiff--entry-dir-p (entry)
  (and entry (eq (dirdiff-entry-type entry) 'dir)))

(defun dirdiff--node-dir-p (node)
  (or (dirdiff--entry-dir-p (dirdiff-node-left node))
      (dirdiff--entry-dir-p (dirdiff-node-right node))))

(defun dirdiff--node-entry (node side)
  (if (eq side 'left) (dirdiff-node-left node) (dirdiff-node-right node)))

(defun dirdiff--session-source (session side)
  (if (eq side 'left) (dirdiff-session-left session) (dirdiff-session-right session)))

(defun dirdiff--other-side (side)
  (if (eq side 'left) 'right 'left))

(defun dirdiff--join (dir name)
  (if (string-empty-p dir) name (concat dir "/" name)))

;;;; Sources

(cl-defgeneric dirdiff-source-children (source rel)
  "Return the entries of directory REL in SOURCE as an alist (NAME . ENTRY).
REL is relative to the root of SOURCE; the root itself is \"\".")

(cl-defgeneric dirdiff-source-file (source entry rel)
  "Return a local file name holding the contents of ENTRY at REL in SOURCE.")

(cl-defgeneric dirdiff-source-path (source rel)
  "Return the local file name of REL in SOURCE, for writing.")

(cl-defgeneric dirdiff-source-copy-to (source entry rel dest)
  "Copy ENTRY at REL in SOURCE to the local file name DEST.
DEST does not exist, or is a file to overwrite.")

(cl-defgeneric dirdiff-source-cleanup (_source)
  "Release resources (such as temporary files) held by SOURCE."
  nil)

(defun dirdiff--ignored-p (name)
  (and dirdiff-use-ignored-names (member name dirdiff-ignored-names)))

(defun dirdiff--fs-entry (file &optional attrs)
  "Return a `dirdiff-entry' for FILE on disk, using ATTRS if given."
  (let* ((attrs (or attrs (file-attributes file)))
         (type (file-attribute-type attrs)))
    (cond
     ((eq type t) (dirdiff-entry-create :type 'dir :file file))
     ;; A symlink to a file is compared by content (git difftool's
     ;; working tree side consists of such links).  Links to directories
     ;; are not followed, to avoid cycles, and neither are broken links.
     ((stringp type)
      (if (and (file-exists-p file) (not (file-directory-p file)))
          (let ((target (file-attributes (file-truename file))))
            (dirdiff-entry-create :type 'file :file file
                                  :size (file-attribute-size target)
                                  :mtime (file-attribute-modification-time target)))
        (dirdiff-entry-create :type 'link :file file)))
     (t (dirdiff-entry-create :type 'file :file file
                              :size (file-attribute-size attrs)
                              :mtime (file-attribute-modification-time attrs))))))

(cl-defmethod dirdiff-source-children ((source dirdiff-dir-source) rel)
  (let ((dir (expand-file-name rel (dirdiff-dir-source-root source)))
        result)
    (when (file-directory-p dir)
      (dolist (f (directory-files-and-attributes
                  dir nil directory-files-no-dot-files-regexp t))
        (unless (dirdiff--ignored-p (car f))
          (push (cons (car f) (dirdiff--fs-entry (expand-file-name (car f) dir) (cdr f)))
                result))))
    result))

(cl-defmethod dirdiff-source-file ((_source dirdiff-source) entry _rel)
  (dirdiff-entry-file entry))

(cl-defmethod dirdiff-source-path ((source dirdiff-dir-source) rel)
  (expand-file-name rel (dirdiff-dir-source-root source)))

(cl-defmethod dirdiff-source-copy-to ((_source dirdiff-source) entry _rel dest)
  (let ((file (dirdiff-entry-file entry)))
    (pcase (dirdiff-entry-type entry)
      ('dir (copy-directory file dest t t nil))
      ('link (make-symbolic-link (file-symlink-p file) dest t))
      (_ (copy-file file dest t t nil t)))))

;;;; Comparing files

(defun dirdiff--read-bytes (file &optional limit)
  "Return the contents of FILE as a unibyte string, at most LIMIT bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil 0 limit)
    (buffer-string)))

(defun dirdiff--binary-file-p (file)
  "Return non-nil if FILE looks binary (has a NUL byte near the start)."
  (string-search "\0" (dirdiff--read-bytes file 8000)))

(defun dirdiff--small-p (&rest sizes)
  (cl-every (lambda (s) (and s (<= s dirdiff-large-file-size))) sizes))

(defun dirdiff--bytes-equal-p (a b sa sb)
  (if (or (dirdiff--small-p sa sb) (not (executable-find "cmp")))
      (string= (dirdiff--read-bytes a) (dirdiff--read-bytes b))
    (zerop (call-process "cmp" nil nil nil "-s" a b))))

(defun dirdiff--strip-whitespace (string)
  ;; Like `diff -w': ignore whitespace within lines, but not line breaks.
  (replace-regexp-in-string "[ \t\f\v\r]+" "" string t t))

(defun dirdiff--text-equal-ignoring-whitespace-p (a b sa sb)
  (if (or (dirdiff--small-p sa sb) (not (executable-find "diff")))
      (string= (dirdiff--strip-whitespace (dirdiff--read-bytes a))
               (dirdiff--strip-whitespace (dirdiff--read-bytes b)))
    (zerop (call-process "diff" nil nil nil "-q" "-w" a b))))

(defun dirdiff--compare-files (a b node)
  "Compare local files A and B, return `same' or `changed'.
Records in NODE whether the files are binary."
  (let* ((attrs-a (file-attributes (file-truename a)))
         (attrs-b (file-attributes (file-truename b)))
         (sa (file-attribute-size attrs-a))
         (sb (file-attribute-size attrs-b)))
    (if (and (eql sa 0) (eql sb 0))
        'same
      (let ((binary (or (dirdiff--binary-file-p a) (dirdiff--binary-file-p b))))
        (setf (dirdiff-node-binary node) binary)
        (if (cond
             ((and binary (not (eql sa sb))) nil)
             ((and binary (eq dirdiff-binary-comparison 'quick))
              (time-equal-p (file-attribute-modification-time attrs-a)
                            (file-attribute-modification-time attrs-b)))
             (binary (dirdiff--bytes-equal-p a b sa sb))
             (dirdiff-ignore-whitespace
              (dirdiff--text-equal-ignoring-whitespace-p a b sa sb))
             ((not (eql sa sb)) nil)
             (t (dirdiff--bytes-equal-p a b sa sb)))
            'same
          'changed)))))

(defun dirdiff--compare-entries (session node)
  "Return the status of NODE, whose sides are both non-directories."
  (let* ((l (dirdiff-node-left node))
         (r (dirdiff-node-right node))
         (lt (dirdiff-entry-type l))
         (rt (dirdiff-entry-type r)))
    (or (and-let* ((oracle (dirdiff-session-oracle session)))
          (funcall oracle session node))
        (cond
         ((and (dirdiff-entry-id l) (dirdiff-entry-id r))
          (if (equal (dirdiff-entry-id l) (dirdiff-entry-id r)) 'same 'changed))
         ((or (eq lt 'link) (eq rt 'link))
          (if (and (eq lt 'link) (eq rt 'link)
                   (equal (file-symlink-p (dirdiff-entry-file l))
                          (file-symlink-p (dirdiff-entry-file r))))
              'same 'changed))
         ((or (eq lt 'module) (eq rt 'module)) 'changed)
         (t
          (condition-case err
              (dirdiff--compare-files
               (dirdiff-source-file (dirdiff-session-left session) l (dirdiff-node-rel node))
               (dirdiff-source-file (dirdiff-session-right session) r (dirdiff-node-rel node))
               node)
            (file-error
             (message "dirdiff: %s" (error-message-string err))
             'changed)))))))

;;;; Building the tree

(defvar dirdiff--progress nil)
(defvar dirdiff--progress-count 0)

(defun dirdiff--dir-status (node)
  "Status of directory NODE derived from its sides and children."
  (let ((l (dirdiff-node-left node)) (r (dirdiff-node-right node)))
    (cond ((not r) 'left)
          ((not l) 'right)
          ((not (eq (dirdiff--entry-dir-p l) (dirdiff--entry-dir-p r))) 'conflict)
          ((cl-every (lambda (c) (eq (dirdiff-node-status c) 'same))
                     (dirdiff-node-children node))
           'same)
          (t 'changed))))

(defun dirdiff--node-status (session node)
  (if (dirdiff--node-dir-p node)
      (dirdiff--dir-status node)
    (cond ((not (dirdiff-node-right node)) 'left)
          ((not (dirdiff-node-left node)) 'right)
          (t (dirdiff--compare-entries session node)))))

(defun dirdiff--sort (nodes)
  "Sort NODES: directories first, then by name."
  (sort nodes (lambda (a b)
                (let ((da (dirdiff--node-dir-p a)) (db (dirdiff--node-dir-p b)))
                  (if (eq da db)
                      (string< (dirdiff-node-name a) (dirdiff-node-name b))
                    da)))))

(defun dirdiff--child-entries (session side node)
  (let ((entry (dirdiff--node-entry node side)))
    (and (dirdiff--entry-dir-p entry)
         (dirdiff-source-children (dirdiff--session-source session side)
                                  (dirdiff-node-rel node)))))

(defun dirdiff--build-children (session node)
  "Compare the contents of directory NODE; return its sorted children."
  (let ((left (dirdiff--child-entries session 'left node))
        (right (make-hash-table :test #'equal))
        children)
    (pcase-dolist (`(,name . ,entry) (dirdiff--child-entries session 'right node))
      (puthash name entry right))
    (dolist (pair left)
      (push (dirdiff--build-node session node (car pair) (cdr pair)
                                 (prog1 (gethash (car pair) right)
                                   (remhash (car pair) right)))
            children))
    (maphash (lambda (name entry)
               (push (dirdiff--build-node session node name nil entry) children))
             right)
    (dirdiff--sort children)))

(defun dirdiff--build-node (session parent name left right)
  (let ((node (dirdiff-node-create :name name :parent parent :left left :right right
                                   :rel (dirdiff--join (dirdiff-node-rel parent) name))))
    (when (and dirdiff--progress (zerop (% (cl-incf dirdiff--progress-count) 50)))
      (progress-reporter-update dirdiff--progress dirdiff--progress-count))
    (when (dirdiff--node-dir-p node)
      (setf (dirdiff-node-children node) (dirdiff--build-children session node)))
    (setf (dirdiff-node-status node) (dirdiff--node-status session node))
    node))

(defun dirdiff--prepare (session)
  (when-let* ((prepare (dirdiff-session-prepare session)))
    (funcall prepare session)))

(defun dirdiff--build-tree (session)
  "Compare both sides of SESSION from scratch."
  (dirdiff--with-options session
    (dirdiff--prepare session)
    (let ((root (dirdiff-node-create :name "" :rel ""
                                     :left (dirdiff-entry-create :type 'dir)
                                     :right (dirdiff-entry-create :type 'dir)))
          (dirdiff--progress (make-progress-reporter "Comparing..."))
          (dirdiff--progress-count 0))
      (setf (dirdiff-node-children root) (dirdiff--build-children session root))
      (setf (dirdiff-node-status root) (dirdiff--dir-status root))
      (progress-reporter-done dirdiff--progress)
      (setf (dirdiff-session-counts session) nil)
      (setf (dirdiff-session-tree session) root))))

(defun dirdiff--refresh-node (session node)
  "Re-compare NODE (after it changed on disk) and update its ancestors."
  ;; If the parent is missing on a side, an action may have created it,
  ;; so refresh from the topmost such ancestor.
  (while (let ((p (dirdiff-node-parent node)))
           (and p (dirdiff-node-parent p)
                (not (and (dirdiff-node-left p) (dirdiff-node-right p)))))
    (setq node (dirdiff-node-parent node)))
  (dirdiff--with-options session
    (dirdiff--prepare session)
    (let* ((parent (dirdiff-node-parent node))
           (name (dirdiff-node-name node))
           (left (cdr (assoc name (dirdiff--child-entries session 'left parent))))
           (right (cdr (assoc name (dirdiff--child-entries session 'right parent)))))
      (if (not (or left right))
          (setf (dirdiff-node-children parent) (delq node (dirdiff-node-children parent)))
        (setf (dirdiff-node-left node) left
              (dirdiff-node-right node) right
              (dirdiff-node-binary node) nil
              (dirdiff-node-children node) (and (dirdiff--node-dir-p node)
                                                (dirdiff--build-children session node))
              (dirdiff-node-status node) (dirdiff--node-status session node)))
      (while parent
        (setf (dirdiff-node-status parent) (dirdiff--dir-status parent))
        (setq parent (dirdiff-node-parent parent)))
      (setf (dirdiff-session-counts session) nil))))

(defun dirdiff--walk (node fn)
  "Call FN on every node below NODE, in display order."
  (dolist (child (dirdiff-node-children node))
    (funcall fn child)
    (dirdiff--walk child fn)))

(defun dirdiff--difference-p (node)
  "Non-nil if NODE is a difference to stop at when navigating.
Changed directories are not; their contents are."
  (let ((status (dirdiff-node-status node)))
    (and (not (eq status 'same))
         (not (and (eq status 'changed) (dirdiff--node-dir-p node)))
         ;; Inside a one-sided directory only the directory itself counts.
         (let ((p (dirdiff-node-parent node)))
           (or (null p) (memq (dirdiff-node-status p) '(same changed)))))))

;;;; Buffer state

(defvar-local dirdiff--session nil)
(defvar-local dirdiff--side 'left "The active side, `left' or `right'.")
(defvar-local dirdiff--width 40 "Width of each column.")
(defvar-local dirdiff--rows [] "Vector of (NODE . DEPTH), one per line.")
(defvar-local dirdiff--cell-overlay nil)
(defvar-local dirdiff--mode-line-status "")

(defun dirdiff--current-node ()
  (get-text-property (pos-bol) 'dirdiff-node))

(defun dirdiff--node-at-point ()
  (or (dirdiff--current-node) (user-error "No entry on this line")))

(defun dirdiff--open-p (node)
  (gethash (dirdiff-node-rel node) (dirdiff-session-open dirdiff--session)))

(defun dirdiff--set-open (node open)
  (puthash (dirdiff-node-rel node) open (dirdiff-session-open dirdiff--session)))

;;;; Rendering

(defun dirdiff--visible-rows (session)
  "Return the list of (NODE . DEPTH) to display for SESSION."
  (let ((open (dirdiff-session-open session))
        (hide (dirdiff-session-hide-identical session))
        rows)
    (cl-labels ((walk (nodes depth)
                  (dolist (node nodes)
                    (unless (and hide (eq (dirdiff-node-status node) 'same))
                      (push (cons node depth) rows)
                      (when (and (dirdiff--node-dir-p node)
                                 (gethash (dirdiff-node-rel node) open))
                        (walk (dirdiff-node-children node) (1+ depth)))))))
      (walk (dirdiff-node-children (dirdiff-session-tree session)) 0))
    (nreverse rows)))

(defun dirdiff--face (node side)
  (let ((entry (dirdiff--node-entry node side)))
    (cond ((not entry) 'dirdiff-absent)
          (t (pcase (dirdiff-node-status node)
               ('same 'dirdiff-same)
               ('changed 'dirdiff-changed)
               ('conflict 'dirdiff-conflict)
               (_ 'dirdiff-new))))))

(defun dirdiff--marker (node)
  "The middle column marker for NODE, in the style of `diff -y'."
  (pcase (dirdiff-node-status node)
    ('same " ")
    ('changed (propertize "|" 'face 'dirdiff-changed))
    ('left (propertize "<" 'face 'dirdiff-new))
    ('right (propertize ">" 'face 'dirdiff-new))
    ('conflict (propertize "!" 'face 'dirdiff-conflict))))

(defun dirdiff--cell (node side depth)
  "Return the text of NODE's cell on SIDE, padded to the column width."
  (let* ((entry (dirdiff--node-entry node side))
         (type (and entry (dirdiff-entry-type entry)))
         (indicator (cond ((not (dirdiff--node-dir-p node)) (nth 2 dirdiff-indicators))
                          ((and entry (not (eq type 'dir))) (nth 2 dirdiff-indicators))
                          ((dirdiff--open-p node) (nth 0 dirdiff-indicators))
                          (t (nth 1 dirdiff-indicators))))
         (suffix (cond ((eq type 'link) "@")
                       ((or (eq type 'dir) (and (not entry) (dirdiff--node-dir-p node))) "/")))
         (text (concat (make-string (* 2 depth) ?\s)
                       (propertize (concat indicator (dirdiff-node-name node) suffix)
                                   'face (dirdiff--face node side)))))
    (truncate-string-to-width text dirdiff--width nil ?\s "…")))

(defun dirdiff--row (node depth)
  (propertize (concat (dirdiff--cell node 'left depth)
                      " " (dirdiff--marker node) " "
                      (dirdiff--cell node 'right depth)
                      "\n")
              'dirdiff-node node))

(defun dirdiff--text-columns (window)
  "Number of columns available for text in WINDOW."
  (- (window-max-chars-per-line window)
     (with-selected-window window
       (if display-line-numbers (+ 2 (line-number-display-width)) 0))
     1))

(defun dirdiff--column-width ()
  (let ((window (get-buffer-window (current-buffer) t)))
    (max 10 (/ (- (if window (dirdiff--text-columns window) 80) 3) 2))))

(defun dirdiff--header-cell (side)
  (let* ((source (dirdiff--session-source dirdiff--session side))
         (label (concat (dirdiff-source-label source)
                        (unless (dirdiff-source-writable source) " [read-only]"))))
    (truncate-string-to-width
     (propertize label 'face (if (eq side dirdiff--side) 'dirdiff-header-active 'dirdiff-header))
     dirdiff--width nil ?\s "…")))

(defun dirdiff--header-line ()
  (when dirdiff--session
    (concat (dirdiff--header-cell 'left) "   " (dirdiff--header-cell 'right))))

(defun dirdiff--count-differences ()
  "Return (CHANGED LEFT-ONLY RIGHT-ONLY CONFLICTS) for the current session."
  (with-memoization (dirdiff-session-counts dirdiff--session)
    (dirdiff--count-differences-1)))

(defun dirdiff--count-differences-1 ()
  (let ((changed 0) (left 0) (right 0) (conflict 0))
    (dirdiff--walk (dirdiff-session-tree dirdiff--session)
                   (lambda (node)
                     (when (dirdiff--difference-p node)
                       (pcase (dirdiff-node-status node)
                         ('changed (cl-incf changed))
                         ('left (cl-incf left))
                         ('right (cl-incf right))
                         ('conflict (cl-incf conflict))))))
    (list changed left right conflict)))

(defun dirdiff--update-mode-line ()
  (let ((s dirdiff--session))
    (setq dirdiff--mode-line-status
          (pcase-let ((`(,changed ,left ,right ,conflict) (dirdiff--count-differences)))
            (concat
             (if (= 0 changed left right conflict)
                 " identical"
               (format " |%d <%d >%d%s" changed left right
                       (if (> conflict 0) (format " !%d" conflict) "")))
             (and (dirdiff-session-hide-identical s) " [hide=]")
             (and (dirdiff-session-ignore-whitespace s) " [-w]")
             (and (eq (dirdiff-session-binary-comparison s) 'full) " [bin:full]"))))
    (force-mode-line-update)))

(defun dirdiff--line-of-node (node)
  "Return the 0-based line of NODE in the buffer, or nil."
  (cl-position node dirdiff--rows :key #'car :test #'eq))

(defun dirdiff--render ()
  "Redraw the buffer, keeping point on the same entry when possible."
  (let* ((inhibit-read-only t)
         (node (dirdiff--current-node))
         (line (1- (line-number-at-pos)))
         (window (get-buffer-window (current-buffer)))
         (offset (and window (count-lines (window-start window) (pos-bol)))))
    (setq dirdiff--width (dirdiff--column-width))
    (erase-buffer)
    (setq dirdiff--rows (vconcat (dirdiff--visible-rows dirdiff--session)))
    (cl-loop for (n . depth) across dirdiff--rows
             do (insert (dirdiff--row n depth)))
    (goto-char (point-min))
    ;; Stay on the same entry, or the nearest visible directory above it.
    (forward-line (min (or (cl-loop for n = node then (dirdiff-node-parent n)
                                    while n
                                    thereis (dirdiff--line-of-node n))
                           line)
                       (max 0 (1- (length dirdiff--rows)))))
    (when (and window offset)
      (set-window-start window (save-excursion (forward-line (- offset)) (point)) t))
    (dirdiff--place)
    (dirdiff--update-mode-line)))

(defun dirdiff--cell-start (side)
  (if (eq side 'right) (+ dirdiff--width 3) 0))

(defun dirdiff--place (&optional from-column)
  "Move point to the active cell of the current row and highlight it.
With FROM-COLUMN, first make the side point is on the active side."
  (when (and (eobp) (bolp) (not (bobp)))
    (forward-line -1))
  (let* ((bol (pos-bol))
         (eol (pos-eol)))
    (when from-column
      (setq dirdiff--side (if (>= (- (point) bol) (+ dirdiff--width 2)) 'right 'left)))
    (let* ((start (min eol (+ bol (dirdiff--cell-start dirdiff--side))))
           (end (min eol (+ start dirdiff--width))))
      (goto-char start)
      (unless (overlayp dirdiff--cell-overlay)
        (setq dirdiff--cell-overlay (make-overlay 1 1))
        (overlay-put dirdiff--cell-overlay 'face 'dirdiff-active-cell)
        (overlay-put dirdiff--cell-overlay 'priority 10))
      (if (< start end)
          (move-overlay dirdiff--cell-overlay start end)
        (delete-overlay dirdiff--cell-overlay)))))

(defun dirdiff--post-command ()
  (when dirdiff--session
    (dirdiff--place t)))

(defun dirdiff--window-size-change (window)
  (with-current-buffer (window-buffer window)
    (when (and dirdiff--session (/= dirdiff--width (dirdiff--column-width)))
      (dirdiff--render))))

(defun dirdiff--goto-node (node)
  "Move point to NODE's row, expanding its ancestors and showing it if needed."
  (let ((hidden (and (dirdiff-session-hide-identical dirdiff--session)
                     (eq (dirdiff-node-status node) 'same))))
    (when hidden
      (setf (dirdiff-session-hide-identical dirdiff--session) nil))
    (let ((p (dirdiff-node-parent node)))
      (while (and p (dirdiff-node-parent p))
        (dirdiff--set-open p t)
        (setq p (dirdiff-node-parent p))))
    (dirdiff--render)
    (when-let* ((line (dirdiff--line-of-node node)))
      (goto-char (point-min))
      (forward-line line)
      (dirdiff--place))))

;;;; Commands: navigation and view

(defun dirdiff-switch-side ()
  "Make the other side active."
  (interactive)
  (setq dirdiff--side (dirdiff--other-side dirdiff--side))
  (dirdiff--place)
  (force-mode-line-update))

(defun dirdiff-select-left ()
  "Make the left side active."
  (interactive)
  (setq dirdiff--side 'left)
  (dirdiff--place))

(defun dirdiff-select-right ()
  "Make the right side active."
  (interactive)
  (setq dirdiff--side 'right)
  (dirdiff--place))

(defun dirdiff-next-line (n)
  "Move N rows down, staying on the active side."
  (interactive "p")
  (forward-line n)
  (dirdiff--place))

(defun dirdiff-previous-line (n)
  "Move N rows up, staying on the active side."
  (interactive "p")
  (dirdiff-next-line (- n)))

(defun dirdiff-next-difference (&optional backward)
  "Move to the next difference, expanding directories as needed.
With BACKWARD, move to the previous one."
  (interactive)
  (let ((current (dirdiff--current-node))
        (passed (not (dirdiff--current-node)))
        found)
    (catch 'done
      (let ((nodes nil))
        (dirdiff--walk (dirdiff-session-tree dirdiff--session)
                       (lambda (n) (push n nodes)))
        (unless backward (setq nodes (nreverse nodes)))
        (dolist (n nodes)
          (cond ((eq n current) (setq passed t))
                ((and passed (dirdiff--difference-p n))
                 (setq found n)
                 (throw 'done nil))))))
    (if found
        (dirdiff--goto-node found)
      (message "No %s difference" (if backward "previous" "next")))))

(defun dirdiff-previous-difference ()
  "Move to the previous difference, expanding directories as needed."
  (interactive)
  (dirdiff-next-difference t))

(defun dirdiff-up ()
  "Move to the parent directory of the current entry."
  (interactive)
  (let ((parent (dirdiff-node-parent (dirdiff--node-at-point))))
    (if (and parent (dirdiff-node-parent parent))
        (dirdiff--goto-node parent)
      (user-error "At top level"))))

(defun dirdiff-toggle ()
  "Expand or collapse the directory on the current row."
  (interactive)
  (let ((node (dirdiff--node-at-point)))
    (unless (dirdiff--node-dir-p node)
      (user-error "Not a directory"))
    (dirdiff--set-open node (not (dirdiff--open-p node)))
    (dirdiff--render)))

(defun dirdiff--set-open-all (pred)
  (dirdiff--walk (dirdiff-session-tree dirdiff--session)
                 (lambda (node)
                   (when (dirdiff--node-dir-p node)
                     (dirdiff--set-open node (funcall pred node))))))

(defun dirdiff-expand-all ()
  "Expand all directories."
  (interactive)
  (dirdiff--set-open-all #'always)
  (dirdiff--render))

(defun dirdiff-collapse-all ()
  "Collapse all directories."
  (interactive)
  (dirdiff--set-open-all #'ignore)
  (dirdiff--render))

(defun dirdiff--changed-dir-p (node)
  (eq (dirdiff-node-status node) 'changed))

(defun dirdiff-expand-changed ()
  "Expand exactly the directories that contain differences."
  (interactive)
  (dirdiff--set-open-all #'dirdiff--changed-dir-p)
  (dirdiff--render))

(defun dirdiff-toggle-hide-identical ()
  "Toggle whether identical files and directories are shown."
  (interactive)
  (setf (dirdiff-session-hide-identical dirdiff--session)
        (not (dirdiff-session-hide-identical dirdiff--session)))
  (dirdiff--render)
  (message "Identical entries %s"
           (if (dirdiff-session-hide-identical dirdiff--session) "hidden" "shown")))

(defun dirdiff-refresh ()
  "Compare both sides again from scratch."
  (interactive)
  (dirdiff--build-tree dirdiff--session)
  (dirdiff--render))

(defun dirdiff-toggle-ignore-whitespace ()
  "Toggle ignoring whitespace in text files, and compare again."
  (interactive)
  (setf (dirdiff-session-ignore-whitespace dirdiff--session)
        (not (dirdiff-session-ignore-whitespace dirdiff--session)))
  (dirdiff-refresh))

(defun dirdiff-toggle-binary-comparison ()
  "Toggle comparing binary files by content or by size and time, and compare again."
  (interactive)
  (setf (dirdiff-session-binary-comparison dirdiff--session)
        (if (eq (dirdiff-session-binary-comparison dirdiff--session) 'full) 'quick 'full))
  (dirdiff-refresh))

(defun dirdiff-toggle-ignored-names ()
  "Toggle leaving out `dirdiff-ignored-names', and compare again."
  (interactive)
  (setf (dirdiff-session-use-ignored-names dirdiff--session)
        (not (dirdiff-session-use-ignored-names dirdiff--session)))
  (dirdiff-refresh))

;;;; Commands: opening files

(defun dirdiff--local-file (node side)
  (when-let* ((entry (dirdiff--node-entry node side)))
    (dirdiff-source-file (dirdiff--session-source dirdiff--session side)
                         entry (dirdiff-node-rel node))))

(defun dirdiff--ediff (node)
  (require 'ediff)
  (let* ((left (dirdiff--local-file node 'left))
         (right (dirdiff--local-file node 'right))
         (buffer (current-buffer))
         (config (current-window-configuration))
         (ediff-diff-options
          (if (dirdiff-session-ignore-whitespace dirdiff--session)
              (string-trim (concat ediff-diff-options " -w"))
            ediff-diff-options))
         (after-quit
          (lambda ()
            (set-window-configuration config)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (dirdiff--refresh-node dirdiff--session node)
                (dirdiff--render))))))
    (ediff-files left right
                 (list (lambda ()
                         ;; ediff ignores the global value of this hook
                         ;; once it has a local one, so include it.
                         (setq-local ediff-after-quit-hook-internal
                                     (append (remq t (default-value
                                                      'ediff-after-quit-hook-internal))
                                             (list after-quit))))))))

(defun dirdiff-open ()
  "Diff the files on the current row, or expand/collapse the directory.
If the file exists on one side only, visit it."
  (interactive)
  (let* ((node (dirdiff--node-at-point))
         (l (dirdiff-node-left node))
         (r (dirdiff-node-right node)))
    (cond
     ((dirdiff--node-dir-p node) (dirdiff-toggle))
     ((not (and l r)) (dirdiff-find-file-other-window))
     ((memq 'module (list (dirdiff-entry-type l) (dirdiff-entry-type r)))
      (message "Submodule %s" (if (eq (dirdiff-node-status node) 'same) "unchanged" "changed")))
     ((dirdiff-node-binary node)
      (message "Binary files are %s" (if (eq (dirdiff-node-status node) 'same)
                                         "identical" "different")))
     (t (dirdiff--ediff node)))))

(defun dirdiff-mouse-open (event)
  "Open the entry clicked on with EVENT, like `dirdiff-open'."
  (interactive "e")
  (mouse-set-point event)
  (dirdiff--place t)
  (dirdiff-open))

(defun dirdiff--active-file ()
  (let* ((node (dirdiff--node-at-point))
         (side (if (dirdiff--node-entry node dirdiff--side)
                   dirdiff--side
                 (dirdiff--other-side dirdiff--side))))
    (dirdiff--local-file node side)))

(defun dirdiff-find-file ()
  "Visit the file or directory on the active side."
  (interactive)
  (find-file (dirdiff--active-file)))

(defun dirdiff-find-file-other-window ()
  "Visit the file or directory on the active side in another window."
  (interactive)
  (find-file-other-window (dirdiff--active-file)))

;;;; Commands: editing

(defun dirdiff--writable-path (node side)
  "Return the local file name of NODE on SIDE, or signal an error."
  (let ((source (dirdiff--session-source dirdiff--session side)))
    (unless (dirdiff-source-writable source)
      (user-error "The %s side (%s) is read-only" side (dirdiff-source-label source)))
    (dirdiff-source-path source (dirdiff-node-rel node))))

(defun dirdiff--delete-local (file)
  (if (and (file-directory-p file) (not (file-symlink-p file)))
      (delete-directory file t t)
    (delete-file file t)))

(defun dirdiff--copy (from)
  "Copy the current entry from side FROM to the other side."
  (let* ((node (dirdiff--node-at-point))
         (to (dirdiff--other-side from))
         (entry (or (dirdiff--node-entry node from)
                    (user-error "Nothing to copy: %s does not exist on the %s side"
                                (dirdiff-node-rel node) from)))
         (dest (dirdiff--writable-path node to))
         (existing (dirdiff--node-entry node to)))
    (when (y-or-n-p (format "%s %s%s to the %s side? "
                            (if existing "Replace" "Copy")
                            (dirdiff-node-rel node)
                            (if (dirdiff--entry-dir-p entry) "/" "")
                            to))
      ;; Directories are replaced as a whole so that both sides end up
      ;; identical; files are overwritten in place (which also writes
      ;; through symlinks, as in git difftool's working tree side).
      (when (and existing (or (dirdiff--entry-dir-p existing) (dirdiff--entry-dir-p entry)
                              (eq (dirdiff-entry-type existing) 'link)))
        (dirdiff--delete-local dest))
      (make-directory (file-name-directory (directory-file-name dest)) t)
      (dirdiff-source-copy-to (dirdiff--session-source dirdiff--session from)
                              entry (dirdiff-node-rel node) dest)
      (dirdiff--refresh-node dirdiff--session node)
      (dirdiff--render))))

(defun dirdiff-copy-to-right ()
  "Copy the current file or directory from the left side to the right side."
  (interactive)
  (dirdiff--copy 'left))

(defun dirdiff-copy-to-left ()
  "Copy the current file or directory from the right side to the left side."
  (interactive)
  (dirdiff--copy 'right))

(defun dirdiff-copy-to-other-side ()
  "Copy the current entry from the active side to the other side."
  (interactive)
  (dirdiff--copy dirdiff--side))

(defun dirdiff-delete ()
  "Delete the current file or directory on the active side.
The file is moved to the trash if `delete-by-moving-to-trash' is non-nil."
  (interactive)
  (let* ((node (dirdiff--node-at-point))
         (side dirdiff--side)
         (entry (or (dirdiff--node-entry node side)
                    (user-error "%s does not exist on the %s side"
                                (dirdiff-node-rel node) side)))
         (file (dirdiff--writable-path node side)))
    (when (yes-or-no-p (format "Delete %s%s on the %s side? "
                               (dirdiff-node-rel node)
                               (if (dirdiff--entry-dir-p entry) "/ and its contents" "")
                               side))
      (dirdiff--delete-local file)
      (dirdiff--refresh-node dirdiff--session node)
      (dirdiff--render))))

(defun dirdiff-quit ()
  "Quit the comparison and kill its buffer."
  (interactive)
  (quit-window t))

;;;; Menus

(transient-define-prefix dirdiff-dispatch ()
  "Show the dirdiff commands."
  [["Move"
    ("n" "Next difference" dirdiff-next-difference :transient t)
    ("p" "Previous difference" dirdiff-previous-difference :transient t)
    ("TAB" "Switch side" dirdiff-switch-side :transient t)
    ("^" "Parent directory" dirdiff-up :transient t)]
   ["Expand"
    ("+" "Expand all" dirdiff-expand-all :transient t)
    ("-" "Collapse all" dirdiff-collapse-all :transient t)
    ("*" "Expand changed" dirdiff-expand-changed :transient t)]
   ["Open"
    ("RET" "Ediff / toggle directory" dirdiff-open)
    ("o" "Visit in other window" dirdiff-find-file-other-window)
    ("f" "Visit" dirdiff-find-file)]]
  [["Show and compare"
    ("=" "Hide identical (toggle)" dirdiff-toggle-hide-identical :transient t)
    ("w" "Ignore whitespace (toggle)" dirdiff-toggle-ignore-whitespace :transient t)
    ("b" "Binary files: full/quick (toggle)" dirdiff-toggle-binary-comparison :transient t)
    ("I" "Ignored names (toggle)" dirdiff-toggle-ignored-names :transient t)
    ("g" "Refresh" dirdiff-refresh :transient t)]
   ["Edit"
    (">" "Copy left to right" dirdiff-copy-to-right)
    ("<" "Copy right to left" dirdiff-copy-to-left)
    ("d" "Delete on active side" dirdiff-delete)]
   ["Quit"
    ("q" "Quit dirdiff" dirdiff-quit)]])

(defvar-keymap dirdiff-mode-map
  :doc "Keymap for `dirdiff-mode'."
  :parent special-mode-map
  "TAB" #'dirdiff-switch-side
  "<backtab>" #'dirdiff-switch-side
  "<left>" #'dirdiff-select-left
  "<right>" #'dirdiff-select-right
  "C-b" #'dirdiff-select-left
  "C-f" #'dirdiff-select-right
  "<down>" #'dirdiff-next-line
  "<up>" #'dirdiff-previous-line
  "C-n" #'dirdiff-next-line
  "C-p" #'dirdiff-previous-line
  "RET" #'dirdiff-open
  "<double-mouse-1>" #'dirdiff-mouse-open
  "<mouse-2>" #'dirdiff-mouse-open
  "SPC" #'dirdiff-toggle
  "o" #'dirdiff-find-file-other-window
  "f" #'dirdiff-find-file
  "n" #'dirdiff-next-difference
  "p" #'dirdiff-previous-difference
  "^" #'dirdiff-up
  "+" #'dirdiff-expand-all
  "-" #'dirdiff-collapse-all
  "*" #'dirdiff-expand-changed
  "=" #'dirdiff-toggle-hide-identical
  "w" #'dirdiff-toggle-ignore-whitespace
  "b" #'dirdiff-toggle-binary-comparison
  "I" #'dirdiff-toggle-ignored-names
  "g" #'dirdiff-refresh
  ">" #'dirdiff-copy-to-right
  "<" #'dirdiff-copy-to-left
  "c" #'dirdiff-copy-to-other-side
  "d" #'dirdiff-delete
  "q" #'dirdiff-quit
  "?" #'dirdiff-dispatch)

(easy-menu-define dirdiff-mode-menu dirdiff-mode-map
  "Menu for `dirdiff-mode'."
  '("Dirdiff"
    ["Next difference" dirdiff-next-difference]
    ["Previous difference" dirdiff-previous-difference]
    ["Switch side" dirdiff-switch-side]
    "---"
    ["Ediff / toggle directory" dirdiff-open]
    ["Visit in other window" dirdiff-find-file-other-window]
    "---"
    ["Expand all" dirdiff-expand-all]
    ["Collapse all" dirdiff-collapse-all]
    ["Expand changed" dirdiff-expand-changed]
    "---"
    ["Hide identical" dirdiff-toggle-hide-identical
     :style toggle :selected (dirdiff-session-hide-identical dirdiff--session)]
    ["Ignore whitespace" dirdiff-toggle-ignore-whitespace
     :style toggle :selected (dirdiff-session-ignore-whitespace dirdiff--session)]
    ["Compare binary files byte by byte" dirdiff-toggle-binary-comparison
     :style toggle :selected (eq (dirdiff-session-binary-comparison dirdiff--session) 'full)]
    ["Leave out ignored names" dirdiff-toggle-ignored-names
     :style toggle :selected (dirdiff-session-use-ignored-names dirdiff--session)]
    ["Refresh" dirdiff-refresh]
    "---"
    ["Copy left to right" dirdiff-copy-to-right]
    ["Copy right to left" dirdiff-copy-to-left]
    ["Delete on active side" dirdiff-delete]
    "---"
    ["Quit" dirdiff-quit]))

(defvar dirdiff-tool-bar-map
  (when (fboundp 'tool-bar-local-item)
    (let ((map (make-sparse-keymap)))
      (tool-bar-local-item "prev-node" #'dirdiff-previous-difference 'dirdiff-prev map
                           :help "Previous difference")
      (tool-bar-local-item "next-node" #'dirdiff-next-difference 'dirdiff-next map
                           :help "Next difference")
      (tool-bar-local-item "zoom-in" #'dirdiff-expand-all 'dirdiff-expand map
                           :help "Expand all")
      (tool-bar-local-item "zoom-out" #'dirdiff-collapse-all 'dirdiff-collapse map
                           :help "Collapse all")
      (tool-bar-local-item "show" #'dirdiff-toggle-hide-identical 'dirdiff-hide map
                           :help "Hide identical entries"
                           :button '(:toggle . (dirdiff-session-hide-identical dirdiff--session)))
      (tool-bar-local-item "refresh" #'dirdiff-refresh 'dirdiff-refresh map
                           :help "Compare again")
      (tool-bar-local-item "right-arrow" #'dirdiff-copy-to-right 'dirdiff-copy-right map
                           :help "Copy left to right")
      (tool-bar-local-item "left-arrow" #'dirdiff-copy-to-left 'dirdiff-copy-left map
                           :help "Copy right to left")
      (tool-bar-local-item "delete" #'dirdiff-delete 'dirdiff-delete map
                           :help "Delete on the active side")
      (tool-bar-local-item "help" #'dirdiff-dispatch 'dirdiff-dispatch map
                           :help "All commands")
      (tool-bar-local-item "close" #'dirdiff-quit 'dirdiff-quit map
                           :help "Quit")
      map))
  "Tool bar for `dirdiff-mode'.")

;;;; Mode

(define-derived-mode dirdiff-mode special-mode "Dirdiff"
  "Major mode for comparing two directory trees side by side.

Each row shows an entry of the left tree in the left column and the
same entry of the right tree in the right column.  The middle column
shows | for changed, < for left only, > for right only and ! for a
file on one side and a directory on the other.  One side is active;
copy, delete and visit act on it.

\\{dirdiff-mode-map}"
  :interactive nil
  (setq truncate-lines t
        buffer-read-only t
        cursor-type nil)
  (setq-local revert-buffer-function (lambda (&rest _) (dirdiff-refresh)))
  (setq-local mode-line-process '(:eval dirdiff--mode-line-status))
  (header-line-indent-mode 1)
  (setq header-line-format '("" header-line-indent (:eval (dirdiff--header-line))))
  (when dirdiff-tool-bar-map
    (setq-local tool-bar-map dirdiff-tool-bar-map))
  (hl-line-mode 1)
  (add-hook 'post-command-hook #'dirdiff--post-command nil t)
  (add-hook 'window-size-change-functions #'dirdiff--window-size-change nil t)
  (add-hook 'kill-buffer-hook #'dirdiff--cleanup nil t))

(defun dirdiff--cleanup-session (session)
  (let ((functions (dirdiff-session-cleanup session)))
    (setf (dirdiff-session-cleanup session) nil)
    (dirdiff-source-cleanup (dirdiff-session-left session))
    (dirdiff-source-cleanup (dirdiff-session-right session))
    (mapc #'funcall functions)))

(defun dirdiff--cleanup ()
  (when dirdiff--session
    (dirdiff--cleanup-session dirdiff--session)))

(defun dirdiff--initial-expansion (session)
  (let ((pred (pcase dirdiff-initial-expansion
                ('all #'always)
                ('none #'ignore)
                (_ #'dirdiff--changed-dir-p))))
    (dirdiff--walk (dirdiff-session-tree session)
                   (lambda (node)
                     (when (and (dirdiff--node-dir-p node) (funcall pred node))
                       (puthash (dirdiff-node-rel node) t (dirdiff-session-open session)))))))

(defun dirdiff-show-session (session &optional buffer-name)
  "Compare the sides of SESSION and display the result.
BUFFER-NAME defaults to one made from the side labels.  Return the buffer."
  (let ((buffer (generate-new-buffer
                 (or buffer-name
                     (format "*dirdiff %s ↔ %s*"
                             (dirdiff-source-label (dirdiff-session-left session))
                             (dirdiff-source-label (dirdiff-session-right session)))))))
    (condition-case err
        (dirdiff--build-tree session)
      ((error quit)
       (kill-buffer buffer)
       (dirdiff--cleanup-session session)
       (signal (car err) (cdr err))))
    (dirdiff--initial-expansion session)
    (pop-to-buffer-same-window buffer)
    (dirdiff-mode)
    (setq dirdiff--session session)
    (dirdiff--render)
    (goto-char (point-min))
    (dirdiff--place)
    (pcase-let ((`(,changed ,left ,right ,conflict) (dirdiff--count-differences)))
      (message (if (= 0 changed left right conflict)
                   "Both sides are identical"
                 (substitute-command-keys
                  "%d changed, %d left only, %d right only%s.  \\<dirdiff-mode-map>\\[dirdiff-dispatch] for commands"))
               changed left right (if (> conflict 0) (format ", %d conflicts" conflict) "")))
    buffer))

;;;; Entry points

(defun dirdiff--dired-marked-p ()
  (save-excursion
    (goto-char (point-min))
    (re-search-forward (dired-marker-regexp) nil t)))

(defun dirdiff--read-paths ()
  "Read two file or directory names, with defaults from Dired."
  (let ((marked (and (derived-mode-p 'dired-mode)
                     (dirdiff--dired-marked-p)
                     (dired-get-marked-files))))
    (if (= (length marked) 2)
        marked
      (let* ((default (and (derived-mode-p 'dired-mode) (dired-get-filename nil t)))
             (a (read-file-name "Left file or directory: " nil default t))
             (other (and (derived-mode-p 'dired-mode)
                         (progn (require 'dired-aux) (dired-dwim-target-directory))))
             (b (read-file-name (format "Compare %s with: " (abbreviate-file-name a))
                                other nil t)))
        (list a b)))))

;;;###autoload
(defun dirdiff (left right)
  "Compare LEFT and RIGHT.
Two directories are compared with `dirdiff-directories'; two files
with `ediff-files'.  In Dired with exactly two marked entries, those
are compared."
  (interactive (dirdiff--read-paths))
  (cond ((and (file-directory-p left) (file-directory-p right))
         (dirdiff-directories left right))
        ((not (or (file-directory-p left) (file-directory-p right)))
         (ediff-files left right))
        (t (user-error "Cannot compare a file with a directory"))))

;;;###autoload
(defun dirdiff-directories (left right)
  "Compare directories LEFT and RIGHT side by side."
  (interactive
   (let ((a (read-directory-name "Left directory: " nil nil t)))
     (list a (read-directory-name (format "Compare %s with: " (abbreviate-file-name a))
                                  nil nil t))))
  (dirdiff-show-session
   (dirdiff-session-create
    :left (dirdiff-dir-source-create :root (file-name-as-directory (expand-file-name left))
                                     :label (abbreviate-file-name left) :writable t)
    :right (dirdiff-dir-source-create :root (file-name-as-directory (expand-file-name right))
                                      :label (abbreviate-file-name right) :writable t))))

;;;###autoload
(defun dirdiff-dired ()
  "Compare the two directories marked in the visible Dired buffers."
  (interactive)
  (let (dirs)
    (dolist (window (window-list))
      (with-current-buffer (window-buffer window)
        (when (and (derived-mode-p 'dired-mode) (dirdiff--dired-marked-p))
          (dolist (f (dired-get-marked-files))
            (unless (member f dirs) (setq dirs (append dirs (list f))))))))
    (unless (and (= (length dirs) 2) (cl-every #'file-directory-p dirs))
      (user-error "Mark exactly two directories (in one or two Dired windows)"))
    (dirdiff-directories (car dirs) (cadr dirs))))

;;;###autoload
(defun dirdiff-difftool (left right &optional done-file standalone)
  "Compare LEFT and RIGHT for `git difftool --dir-diff'.
This is called by the `dirdiff-difftool' script.  When the comparison
is quit, DONE-FILE is deleted, which tells the waiting script that git
may clean up.  With STANDALONE, Emacs exits when the comparison is quit."
  (let ((buffer (dirdiff-directories left right)))
    (with-current-buffer buffer
      (setf (dirdiff-session-hide-identical dirdiff--session) t)
      (dirdiff--render)
      (push (lambda ()
              (when (and done-file (file-exists-p done-file))
                (delete-file done-file))
              (when standalone
                (run-at-time 0 nil #'kill-emacs)))
            (dirdiff-session-cleanup dirdiff--session)))
    (select-frame-set-input-focus (selected-frame))
    buffer))

(provide 'dirdiff)
;;; dirdiff.el ends here
