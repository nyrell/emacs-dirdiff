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
;; One side is "active" (highlighted and marked ▶); TAB switches side.  RET on a file
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
;;
;; Structure: each side of a comparison is a "source" (a directory on
;; disk, or a git revision in dirdiff-git.el) that lists entries.  The
;; two listings are merged into a tree of nodes, one per row, and the
;; buffer is redrawn from that tree and the set of expanded directories.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'diff-mode)                    ; faces we inherit from
(require 'transient)

(declare-function dired-get-marked-files "dired")
(declare-function dired-marker-regexp "dired")
(declare-function dired-dwim-target-directory "dired-aux")
(defvar ediff-diff-options)
(defvar ediff-after-quit-hook-internal)

;;;; Customization

(defgroup dirdiff nil
  "Compare directory trees side by side."
  :group 'tools
  :prefix "dirdiff-")

(defcustom dirdiff-ignored-names '(".git" ".hg" ".svn" ".bzr" "_darcs" "CVS")
  "File and directory names to leave out of directory comparisons."
  :type '(repeat string))

(defcustom dirdiff-ignore-whitespace nil
  "Non-nil means text files differing only in whitespace are identical.
This corresponds to `diff -w'.  It also applies to ediff sessions
started from dirdiff."
  :type 'boolean)

(defcustom dirdiff-ignore-line-endings t
  "Non-nil means text files differing only in line endings are identical.
A file with Windows line endings (CRLF) is then the same as one with
Unix line endings (LF).  It also applies to ediff sessions started
from dirdiff."
  :type 'boolean)

(defcustom dirdiff-ignore-file-modes t
  "Non-nil means files differing only in their executable bit are identical.
nil reports such files as changed, as git does."
  :type 'boolean)

(defcustom dirdiff-save-after-ediff 'ask
  "Whether to save the files changed in ediff when it quits.
`ask' asks for each changed file, t saves without asking and nil
leaves them unsaved.  The entry is compared again afterwards, using
the files as saved on disk."
  :type '(choice (const :tag "Ask" ask)
                 (const :tag "Save without asking" t)
                 (const :tag "Do not save" nil)))

(defcustom dirdiff-binary-comparison 'quick
  "How to compare binary files.
`quick' compares size and modification time only.  `full' compares
the contents byte by byte."
  :type '(choice (const :tag "Size and modification time" quick)
                 (const :tag "Contents, byte by byte" full)))

(defcustom dirdiff-hide-identical nil
  "Non-nil means identical entries are hidden when comparing directories.
Git comparisons always start with identical entries hidden.  Toggle
in the dirdiff buffer with \\<dirdiff-mode-map>\\[dirdiff-toggle-hide-identical]."
  :type 'boolean)

(defcustom dirdiff-initial-expansion 'changed
  "Which directories to expand when a comparison is first shown.
`changed' expands directories present on both sides that contain
differences, `all' expands everything and `none' nothing."
  :type '(choice (const :tag "Directories with differences" changed)
                 (const :tag "All" all)
                 (const :tag "None" none)))

(defcustom dirdiff-new-frame 'magit
  "Whether to show a comparison in a new frame.
nil shows it in the selected window and t always in a new frame.
`magit' uses a new frame when the comparison is started from a magit
buffer, which leaves magit's windows as they were.  Quitting with
\\<dirdiff-mode-map>\\[dirdiff-quit] deletes a frame made this way."
  :type '(choice (const :tag "Selected window" nil)
                 (const :tag "New frame" t)
                 (const :tag "New frame when started from magit" magit)))

(defcustom dirdiff-replace-dired-windows t
  "Non-nil means a comparison of two directories shown in Dired replaces them.
When both directories are shown in Dired windows in the selected frame,
the comparison takes the place of both windows, and quitting it with
\\<dirdiff-mode-map>\\[dirdiff-quit] restores the windows as they were.
This does not apply when the comparison gets a new frame (see
`dirdiff-new-frame')."
  :type 'boolean)

(defcustom dirdiff-frame-parameters '((fullscreen . maximized))
  "Frame parameters for the frames made according to `dirdiff-new-frame'."
  :type '(alist :key-type symbol :value-type sexp))

(defconst dirdiff--large-file-size (* 8 1024 1024)
  "Larger files are compared with `cmp' or `diff' instead of in Lisp.")

;;;; Faces

(defface dirdiff-same '((t :inherit default))
  "Face for entries that are identical on both sides.")

(defface dirdiff-changed '((t :inherit diff-indicator-changed :weight bold))
  "Face for files that differ and directories containing differences.")

(defface dirdiff-new '((t :inherit diff-indicator-added :weight bold))
  "Face for entries present on this side only.")

(defface dirdiff-conflict '((t :inherit diff-indicator-removed :weight bold))
  "Face for entries that are a file on one side and a directory on the other.")

(defface dirdiff-absent '((t :inherit shadow :strike-through t))
  "Face for the name of an entry that does not exist on this side.")

(defface dirdiff-active-cell '((t :inherit region :extend nil))
  "Face for the active side of the current row.")

(defface dirdiff-active-marker '((t :weight bold))
  "Face for the ▶ that marks the active side.")

(defface dirdiff-header '((t :inherit shadow))
  "Face for the label of the inactive side in the header line.")

(defface dirdiff-header-active '((t :weight bold))
  "Face for the label of the active side in the header line.")

;;;; Data model

(cl-defstruct (dirdiff-entry (:constructor dirdiff-entry-create)
                             (:copier nil))
  "What exists at a path on one side."
  type   ; `file', `dir', `link' (symlink not followed) or `module'
  file   ; local file name, or nil when not on disk (git revision)
  size mtime
  id     ; git object id, when known
  mode)  ; git file mode string, when known

(cl-defstruct (dirdiff-node (:constructor dirdiff-node-create)
                            (:copier nil))
  "A row in the comparison: a relative path and both sides of it."
  name rel parent left right status children)
;; STATUS is `same', `changed', `left' (left only), `right' (right
;; only) or `conflict' (file on one side, directory on the other).

(cl-defstruct (dirdiff-source (:constructor nil) (:copier nil))
  "Where one side of the comparison comes from.
WRITABLE is nil (read-only), t, or `working-tree': only the files
that git difftool took from the working tree may be overwritten, see
`dirdiff--working-tree-file'."
  label writable)

(cl-defstruct (dirdiff-dir-source (:include dirdiff-source)
                                  (:constructor dirdiff-dir-source-create)
                                  (:copier nil))
  "A directory on disk.
If ONLY is a hash table, it lists the relative names to include,
mapped to `file' or `dir' (used for git working trees); otherwise
everything except `dirdiff-ignored-names' is included.
COPIES maps relative names to working tree files, for the files that
git difftool copied from the working tree (instead of linking to them)
and copies back when the tool exits."
  root only copies)

(cl-defstruct (dirdiff-session (:constructor dirdiff-session-create)
                               (:copier nil))
  left right                            ; sources
  tree                                  ; root node
  (open (make-hash-table :test #'equal)) ; rel -> t for expanded dirs
  ;; PREPARE is nil, or a function called with the session before
  ;; comparing, returning nil or a function NODE -> status.
  prepare
  cleanup     ; list of functions run when the buffer is killed
  counts      ; (CHANGED LEFT-ONLY RIGHT-ONLY CONFLICTS)
  (ignore-whitespace dirdiff-ignore-whitespace)
  (ignore-line-endings dirdiff-ignore-line-endings)
  (ignore-modes dirdiff-ignore-file-modes)
  (binary-comparison dirdiff-binary-comparison)
  (hide-identical dirdiff-hide-identical))

(defun dirdiff--entry-dir-p (entry)
  "Non-nil if ENTRY is a directory."
  (and entry (eq (dirdiff-entry-type entry) 'dir)))

(defun dirdiff--node-dir-p (node)
  "Non-nil if NODE is a directory on either side."
  (or (dirdiff--entry-dir-p (dirdiff-node-left node))
      (dirdiff--entry-dir-p (dirdiff-node-right node))))

(defun dirdiff--node-entry (node side)
  "Return the entry of NODE on SIDE, `left' or `right'."
  (if (eq side 'left) (dirdiff-node-left node) (dirdiff-node-right node)))

(defun dirdiff--session-source (session side)
  "Return the source of SESSION on SIDE."
  (if (eq side 'left) (dirdiff-session-left session) (dirdiff-session-right session)))

(defun dirdiff--other-side (side)
  "Return the side opposite to SIDE."
  (if (eq side 'left) 'right 'left))

;;;; Sources

(cl-defgeneric dirdiff-source-children (source rel)
  "Return the entries of directory REL in SOURCE as an alist (NAME . ENTRY).
REL is relative to the root of SOURCE; the root itself is \"\".")

(cl-defgeneric dirdiff-source-file (source entry rel)
  "Return a local file name holding the contents of ENTRY at REL in SOURCE.")

(cl-defgeneric dirdiff-source-copy-to (source entry rel dest)
  "Copy ENTRY at REL in SOURCE to the local file name DEST.")

(cl-defgeneric dirdiff-source-name (source rel)
  "Return the full name of REL in SOURCE, for `dirdiff-copy-filename-as-kill'.")

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
  "List directory REL of SOURCE, leaving out ignored or unlisted names."
  (let ((dir (expand-file-name rel (dirdiff-dir-source-root source)))
        (only (dirdiff-dir-source-only source))
        result)
    (when (file-directory-p dir)
      (dolist (f (directory-files-and-attributes
                  dir nil directory-files-no-dot-files-regexp t))
        (let ((kind (and only (gethash (file-name-concat rel (car f)) only))))
          (when (if only kind (not (member (car f) dirdiff-ignored-names)))
            (let ((entry (dirdiff--fs-entry (expand-file-name (car f) dir) (cdr f))))
              ;; A directory that git lists as a file is a submodule.
              (when (and (eq kind 'file) (eq (dirdiff-entry-type entry) 'dir))
                (setf (dirdiff-entry-type entry) 'module))
              (push (cons (car f) entry) result))))))
    result))

(cl-defmethod dirdiff-source-file ((_source dirdiff-dir-source) entry _rel)
  "Return the file of ENTRY itself."
  (dirdiff-entry-file entry))

(cl-defmethod dirdiff-source-name ((source dirdiff-dir-source) rel)
  "Return the absolute file name of REL, in the working tree for git difftool."
  (or (and (eq (dirdiff-source-writable source) 'working-tree)
           (dirdiff--working-tree-file source rel))
      (expand-file-name rel (dirdiff-dir-source-root source))))

(cl-defmethod dirdiff-source-copy-to ((_source dirdiff-dir-source) entry _rel dest)
  "Copy ENTRY's file to DEST, keeping times and permissions."
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
  "Return non-nil if FILE seems binary (has a NUL byte near the start)."
  (string-search "\0" (dirdiff--read-bytes file 8000)))

(defun dirdiff--equal-p (a b sizes program args normalize)
  "Non-nil if files A and B are equal after NORMALIZE.
Small files (by SIZES) are compared in Lisp, large ones by running
PROGRAM with ARGS, if it is available."
  (if (or (cl-every (lambda (s) (and s (<= s dirdiff--large-file-size))) sizes)
          (not (executable-find program)))
      (string= (funcall normalize (dirdiff--read-bytes a))
               (funcall normalize (dirdiff--read-bytes b)))
    (zerop (apply #'call-process program nil nil nil (append args (list a b))))))

(defun dirdiff--strip-whitespace (string)
  "Remove whitespace within lines from STRING, like `diff -w'."
  (replace-regexp-in-string "[ \t\f\v\r]+" "" string t t))

(defun dirdiff--strip-cr (string)
  "Turn the CRLF line endings in STRING into LF."
  (string-replace "\r\n" "\n" string))

(defun dirdiff--compare-files (session a b quick)
  "Compare local files A and B using the options of SESSION.
Return `same' or `changed'.  QUICK nil means that the modification
times of A and B cannot be compared, so binary files are compared
byte by byte even if SESSION says to compare them quickly."
  (let* ((attrs-a (file-attributes (file-truename a)))
         (attrs-b (file-attributes (file-truename b)))
         (sa (file-attribute-size attrs-a))
         (sb (file-attribute-size attrs-b))
         (sizes (list sa sb)))
    (if (and (eql sa 0) (eql sb 0))
        'same
      (let ((binary (or (dirdiff--binary-file-p a) (dirdiff--binary-file-p b))))
        (if (cond
             ((and binary (not (eql sa sb))) nil)
             ((and binary quick (eq (dirdiff-session-binary-comparison session) 'quick))
              (time-equal-p (file-attribute-modification-time attrs-a)
                            (file-attribute-modification-time attrs-b)))
             ((and (not binary) (dirdiff-session-ignore-whitespace session))
              (dirdiff--equal-p a b sizes "diff" '("-q" "-w") #'dirdiff--strip-whitespace))
             ((and (not binary) (dirdiff-session-ignore-line-endings session))
              (dirdiff--equal-p a b sizes "diff" '("-q" "--strip-trailing-cr")
                                #'dirdiff--strip-cr))
             ((not (eql sa sb)) nil)
             (t (dirdiff--equal-p a b sizes "cmp" '("-s") #'identity)))
            'same
          'changed)))))

(defvar dirdiff--status-function nil
  "While comparing: nil, or a function returning a node's status.
It is what the session's `prepare' function returned.")

(defun dirdiff--compare-entries (session node)
  "Return the status in SESSION of NODE, whose sides are not directories."
  (let* ((l (dirdiff-node-left node))
         (r (dirdiff-node-right node))
         (lt (dirdiff-entry-type l))
         (rt (dirdiff-entry-type r)))
    (or (and dirdiff--status-function (funcall dirdiff--status-function node))
        (condition-case err
            (cl-flet ((file (side) (dirdiff-source-file (dirdiff--session-source session side)
                                                        (dirdiff--node-entry node side)
                                                        (dirdiff-node-rel node))))
              (cond
               ((or (eq lt 'link) (eq rt 'link))
                (if (and (eq lt 'link) (eq rt 'link)
                         (equal (dirdiff--link-target l (file 'left))
                                (dirdiff--link-target r (file 'right))))
                    'same 'changed))
               ((or (eq lt 'module) (eq rt 'module)) 'changed)
               ((and (not (dirdiff-session-ignore-modes session))
                     (not (eq (dirdiff--executable-p l) (dirdiff--executable-p r))))
                'changed)
               (t (dirdiff--compare-files session (file 'left) (file 'right)
                                          (and (dirdiff-entry-mtime l)
                                               (dirdiff-entry-mtime r))))))
          (file-error
           (message "dirdiff: %s" (error-message-string err))
           'changed)))))

(defun dirdiff--link-target (entry file)
  "The target of symbolic link ENTRY, whose contents are in local FILE.
For a link in a git revision, FILE holds the target as its contents."
  (if (dirdiff-entry-file entry)
      (file-symlink-p file)
    (decode-coding-string (dirdiff--read-bytes file) 'utf-8)))

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
  "Return the status of NODE in SESSION."
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
  "Return the entries of directory NODE on SIDE of SESSION, or nil."
  (and (dirdiff--entry-dir-p (dirdiff--node-entry node side))
       (dirdiff-source-children (dirdiff--session-source session side)
                                (dirdiff-node-rel node))))

(defun dirdiff--build-children (session node)
  "Compare the contents of directory NODE in SESSION; return its children."
  (let ((right (make-hash-table :test #'equal))
        children)
    (pcase-dolist (`(,name . ,entry) (dirdiff--child-entries session 'right node))
      (puthash name entry right))
    (pcase-dolist (`(,name . ,entry) (dirdiff--child-entries session 'left node))
      (push (dirdiff--build-node session node name entry (gethash name right)) children)
      (remhash name right))
    (maphash (lambda (name entry)
               (push (dirdiff--build-node session node name nil entry) children))
             right)
    (dirdiff--sort children)))

(defun dirdiff--build-node (session parent name left right)
  "Make the node NAME under PARENT with entries LEFT and RIGHT.
Compare it, and its contents if it is a directory, using SESSION."
  (let ((node (dirdiff-node-create :name name :parent parent :left left :right right
                                   :rel (file-name-concat (dirdiff-node-rel parent) name))))
    (when (and dirdiff--progress (zerop (% (cl-incf dirdiff--progress-count) 50)))
      (progress-reporter-update dirdiff--progress dirdiff--progress-count))
    (when (dirdiff--node-dir-p node)
      (setf (dirdiff-node-children node) (dirdiff--build-children session node)))
    (setf (dirdiff-node-status node) (dirdiff--node-status session node))
    node))

(defun dirdiff--prepare (session)
  "Run the `prepare' function of SESSION; return its status function."
  (and (dirdiff-session-prepare session)
       (funcall (dirdiff-session-prepare session) session)))

(defun dirdiff--build-tree (session)
  "Compare both sides of SESSION from scratch."
  (let ((dirdiff--status-function (dirdiff--prepare session))
        (dirdiff--progress (make-progress-reporter "Comparing..."))
        (dirdiff--progress-count 0)
        (root (dirdiff-node-create :name "" :rel ""
                                   :left (dirdiff-entry-create :type 'dir)
                                   :right (dirdiff-entry-create :type 'dir))))
    (setf (dirdiff-node-children root) (dirdiff--build-children session root))
    (setf (dirdiff-node-status root) (dirdiff--dir-status root))
    (progress-reporter-done dirdiff--progress)
    (setf (dirdiff-session-tree session) root)
    (dirdiff--count-differences session)))

(defun dirdiff--refresh-node (session node)
  "Compare NODE of SESSION again after it changed; update its ancestors."
  ;; If the parent is missing on a side, an action may have created it,
  ;; so refresh from the topmost such ancestor.
  (while (let ((p (dirdiff-node-parent node)))
           (and p (dirdiff-node-parent p)
                (not (and (dirdiff-node-left p) (dirdiff-node-right p)))))
    (setq node (dirdiff-node-parent node)))
  (let* ((dirdiff--status-function (dirdiff--prepare session))
         (parent (dirdiff-node-parent node))
         (name (dirdiff-node-name node))
         (left (cdr (assoc name (dirdiff--child-entries session 'left parent))))
         (right (cdr (assoc name (dirdiff--child-entries session 'right parent)))))
    (if (not (or left right))
        (setf (dirdiff-node-children parent) (delq node (dirdiff-node-children parent)))
      (setf (dirdiff-node-left node) left
            (dirdiff-node-right node) right
            (dirdiff-node-children node) (and (dirdiff--node-dir-p node)
                                              (dirdiff--build-children session node))
            (dirdiff-node-status node) (dirdiff--node-status session node)))
    (while parent
      (setf (dirdiff-node-status parent) (dirdiff--dir-status parent))
      (setq parent (dirdiff-node-parent parent)))
    (dirdiff--count-differences session)))

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

(defun dirdiff--count-differences (session)
  "Count the differences in SESSION and store them in its `counts'."
  (let ((counts (list 0 0 0 0)))
    (dirdiff--walk (dirdiff-session-tree session)
                   (lambda (node)
                     (when (dirdiff--difference-p node)
                       (cl-incf (nth (pcase (dirdiff-node-status node)
                                       ('changed 0) ('left 1) ('right 2) ('conflict 3))
                                     counts)))))
    (setf (dirdiff-session-counts session) counts)))

(defun dirdiff--summary (session)
  "Describe the differences in SESSION in words."
  (pcase-let ((`(,changed ,left ,right ,conflict) (dirdiff-session-counts session)))
    (if (= 0 changed left right conflict)
        "identical"
      (format "%d changed, %d left only, %d right only%s" changed left right
              (if (> conflict 0) (format ", %d conflicts" conflict) "")))))

;;;; Buffer state

(defvar-local dirdiff--session nil)
(defvar-local dirdiff--side 'left "The active side, `left' or `right'.")
(defvar-local dirdiff--width 40 "Width of each column.")
(defvar-local dirdiff--rows [] "Vector of (NODE . DEPTH), one per line.")
(defvar-local dirdiff--cell-overlay nil)
(defvar-local dirdiff--marker-overlay nil)
(defvar-local dirdiff--window-configuration nil
  "The window configuration to restore when quitting, or nil.")

(defun dirdiff--current-node ()
  "Return the node on the current line, or nil."
  (get-text-property (pos-bol) 'dirdiff-node))

(defun dirdiff--node-at-point ()
  "Return the node on the current line, or signal a `user-error'."
  (or (dirdiff--current-node) (user-error "No entry on this line")))

(defun dirdiff--open-p (node)
  "Non-nil if directory NODE is expanded."
  (gethash (dirdiff-node-rel node) (dirdiff-session-open dirdiff--session)))

(defun dirdiff--set-open (node open)
  "Expand directory NODE if OPEN is non-nil, else collapse it."
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
  "Return the face for NODE's cell on SIDE."
  (if (not (dirdiff--node-entry node side))
      'dirdiff-absent
    (pcase (dirdiff-node-status node)
      ('same 'dirdiff-same)
      ('changed 'dirdiff-changed)
      ('conflict 'dirdiff-conflict)
      (_ 'dirdiff-new))))

(defun dirdiff--marker (node)
  "The middle column marker for NODE, in the style of `diff -y'."
  (pcase (dirdiff-node-status node)
    ('same " ")
    ('changed (propertize "|" 'face 'dirdiff-changed))
    ('left (propertize "<" 'face 'dirdiff-new))
    ('right (propertize ">" 'face 'dirdiff-new))
    ('conflict (propertize "!" 'face 'dirdiff-conflict))))

(defun dirdiff--cell (node side depth)
  "Return the text of NODE's cell on SIDE at DEPTH, padded to the column width."
  (let* ((entry (dirdiff--node-entry node side))
         (type (and entry (dirdiff-entry-type entry)))
         (dir (and (dirdiff--node-dir-p node) (memq type '(nil dir))))
         ;; The first column is left free for the active side's ▶.
         (text (concat (make-string (1+ (* 2 depth)) ?\s)
                       (propertize (concat (cond ((not dir) "  ")
                                                 ((dirdiff--open-p node) "▾ ")
                                                 (t "▸ "))
                                           (dirdiff-node-name node)
                                           (cond (dir "/") ((eq type 'link) "@")))
                                   'face (dirdiff--face node side)))))
    (propertize (truncate-string-to-width text dirdiff--width nil ?\s "…")
                'dirdiff-side side)))

(defun dirdiff--row (node depth)
  "Return the line of text for NODE at DEPTH."
  (propertize (concat (dirdiff--cell node 'left depth)
                      " " (dirdiff--marker node) " "
                      (dirdiff--cell node 'right depth)
                      "\n")
              'dirdiff-node node))

(defun dirdiff--column-width ()
  "Width of each column in the window showing the current buffer."
  (let ((window (get-buffer-window nil t)))
    (max 10 (/ (- (if window
                      (- (window-max-chars-per-line window)
                         ;; Line numbers take up text columns too.
                         (with-selected-window window
                           (if display-line-numbers (+ 2 (line-number-display-width)) 0))
                         1)
                    80)
                  3)
               2))))

(defun dirdiff--header-line ()
  "Return the header line: the labels of both sides."
  (when dirdiff--session
    (cl-flet ((cell (side)
                (let ((source (dirdiff--session-source dirdiff--session side)))
                  (truncate-string-to-width
                   (propertize (concat (if (eq side dirdiff--side) "▶ " "  ")
                                       (dirdiff-source-label source)
                                       (unless (dirdiff-source-writable source)
                                         " [read-only]"))
                               'face (if (eq side dirdiff--side)
                                         'dirdiff-header-active
                                       'dirdiff-header))
                   dirdiff--width nil ?\s "…"))))
      (concat (cell 'left) "   " (cell 'right)))))

(defun dirdiff--mode-line ()
  "Return the mode line summary of differences and options."
  (let ((s dirdiff--session))
    (when s
      (pcase-let ((`(,changed ,left ,right ,conflict) (dirdiff-session-counts s)))
        (concat
         (if (= 0 changed left right conflict)
             " identical"
           (format " |%d <%d >%d%s" changed left right
                   (if (> conflict 0) (format " !%d" conflict) "")))
         (and (dirdiff-session-hide-identical s) " [hide=]")
         (and (dirdiff-session-ignore-whitespace s) " [-w]")
         (and (not (dirdiff-session-ignore-line-endings s)) " [eol]")
         (and (not (dirdiff-session-ignore-modes s)) " [x]")
         (and (eq (dirdiff-session-binary-comparison s) 'full) " [bin:full]"))))))

(defun dirdiff--line-of-node (node)
  "Return the 0-based line of NODE in the buffer, or nil."
  (cl-position node dirdiff--rows :key #'car :test #'eq))

(defun dirdiff--render ()
  "Redraw the buffer, keeping point on the same entry when possible."
  (let* ((inhibit-read-only t)
         (node (dirdiff--current-node))
         (line (1- (line-number-at-pos)))
         (window (get-buffer-window nil t))
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
    (when window
      (set-window-start window (save-excursion (forward-line (- offset)) (point)) t))
    (dirdiff--place)
    (force-mode-line-update)))

(defun dirdiff--place ()
  "Move point to the active cell of the current row and highlight it."
  (when (and (eobp) (bolp) (not (bobp)))
    (forward-line -1))
  (let* ((eol (pos-eol))
         (start (or (text-property-any (pos-bol) eol 'dirdiff-side dirdiff--side)
                    (pos-bol)))
         (end (next-single-property-change start 'dirdiff-side nil eol)))
    (goto-char start)
    (unless (overlayp dirdiff--cell-overlay)
      (setq dirdiff--cell-overlay (make-overlay 1 1)
            dirdiff--marker-overlay (make-overlay 1 1))
      (overlay-put dirdiff--cell-overlay 'face 'dirdiff-active-cell)
      (overlay-put dirdiff--cell-overlay 'priority 10)
      (overlay-put dirdiff--marker-overlay 'display
                   (propertize "▶" 'face '(dirdiff-active-marker dirdiff-active-cell))))
    (move-overlay dirdiff--cell-overlay start end)
    (if (< start end)
        (move-overlay dirdiff--marker-overlay start (1+ start))
      (delete-overlay dirdiff--marker-overlay))))

(defun dirdiff--post-command ()
  "Keep point and the highlight on the active cell."
  (when dirdiff--session
    (dirdiff--place)))

(defun dirdiff--window-size-change (window)
  "Redraw the buffer in WINDOW if its column width changed."
  (with-current-buffer (window-buffer window)
    (when (and dirdiff--session (/= dirdiff--width (dirdiff--column-width)))
      (dirdiff--render))))

(defun dirdiff--goto-node (node)
  "Move point to NODE's row, expanding its ancestors."
  (let ((p (dirdiff-node-parent node)))
    (while (and p (dirdiff-node-parent p))
      (dirdiff--set-open p t)
      (setq p (dirdiff-node-parent p))))
  (dirdiff--render)
  (when-let* ((line (dirdiff--line-of-node node)))
    (goto-char (point-min))
    (forward-line line)
    (dirdiff--place)))

;;;; Commands: moving around

(defun dirdiff--set-side (side)
  "Make SIDE the active side."
  (setq dirdiff--side side)
  (dirdiff--place)
  (force-mode-line-update))

(defun dirdiff-switch-side ()
  "Make the other side active."
  (interactive)
  (dirdiff--set-side (dirdiff--other-side dirdiff--side)))

(defun dirdiff-mouse-select (event)
  "Select the row and side clicked on with EVENT."
  (interactive "e")
  (mouse-set-point event)
  (dirdiff--set-side (or (get-text-property (point) 'dirdiff-side) dirdiff--side)))

(defun dirdiff-next-difference (&optional backward)
  "Move to the next difference, expanding directories as needed.
With BACKWARD, move to the previous one."
  (interactive)
  (let* ((current (dirdiff--current-node))
         (passed (not current))
         nodes)
    (dirdiff--walk (dirdiff-session-tree dirdiff--session) (lambda (n) (push n nodes)))
    (unless backward (setq nodes (nreverse nodes)))
    (if-let* ((found (cl-find-if (lambda (n)
                                   (if (eq n current)
                                       (progn (setq passed t) nil)
                                     (and passed (dirdiff--difference-p n))))
                                 nodes)))
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

;;;; Commands: what is shown

(defun dirdiff--set-open-all (pred)
  "Expand the directories for which PRED is non-nil, collapse the rest."
  (dirdiff--walk (dirdiff-session-tree dirdiff--session)
                 (lambda (node)
                   (when (dirdiff--node-dir-p node)
                     (dirdiff--set-open node (funcall pred node)))))
  (dirdiff--render))

(defun dirdiff-expand-all ()
  "Expand all directories."
  (interactive)
  (dirdiff--set-open-all #'always))

(defun dirdiff-collapse-all ()
  "Collapse all directories."
  (interactive)
  (dirdiff--set-open-all #'ignore))

(defun dirdiff--changed-dir-p (node)
  "Non-nil if NODE has the status `changed'."
  (eq (dirdiff-node-status node) 'changed))

(defun dirdiff-expand-changed ()
  "Expand exactly the directories that contain differences."
  (interactive)
  (dirdiff--set-open-all #'dirdiff--changed-dir-p))

(defun dirdiff-toggle-hide-identical ()
  "Toggle whether identical files and directories are shown."
  (interactive)
  (cl-callf not (dirdiff-session-hide-identical dirdiff--session))
  (dirdiff--render))

(defun dirdiff-refresh ()
  "Compare both sides again from scratch."
  (interactive)
  (dirdiff--build-tree dirdiff--session)
  (dirdiff--render))

(defun dirdiff-toggle-ignore-whitespace ()
  "Toggle ignoring whitespace in text files, and compare again."
  (interactive)
  (cl-callf not (dirdiff-session-ignore-whitespace dirdiff--session))
  (dirdiff-refresh))

(defun dirdiff-toggle-ignore-line-endings ()
  "Toggle ignoring CRLF versus LF line endings in text files, and compare again."
  (interactive)
  (cl-callf not (dirdiff-session-ignore-line-endings dirdiff--session))
  (dirdiff-refresh))

(defun dirdiff-toggle-ignore-modes ()
  "Toggle ignoring changes of the executable bit, and compare again."
  (interactive)
  (cl-callf not (dirdiff-session-ignore-modes dirdiff--session))
  (dirdiff-refresh))

(defun dirdiff-toggle-binary-comparison ()
  "Toggle comparing binary files by content or by size and time, and compare again."
  (interactive)
  (setf (dirdiff-session-binary-comparison dirdiff--session)
        (if (eq (dirdiff-session-binary-comparison dirdiff--session) 'full) 'quick 'full))
  (dirdiff-refresh))

;;;; Commands: opening files

(defun dirdiff--local-file (node side)
  "Return a local file with NODE's contents on SIDE, or nil if absent."
  (when-let* ((entry (dirdiff--node-entry node side)))
    (dirdiff-source-file (dirdiff--session-source dirdiff--session side)
                         entry (dirdiff-node-rel node))))

(defun dirdiff--ediff (node)
  "Run ediff on the files of NODE; compare NODE again when ediff quits.
A side where the file is missing is shown as an empty, read-only file."
  (require 'ediff)
  (let* ((absent-dir (unless (and (dirdiff-node-left node) (dirdiff-node-right node))
                       (make-temp-file "dirdiff-absent-" t)))
         (absent (and absent-dir
                      ;; The same name, so ediff picks the same major mode;
                      ;; the directory makes the buffer name end in <missing>.
                      (let ((file (expand-file-name (dirdiff-node-name node)
                                                    (expand-file-name "missing" absent-dir))))
                        (make-directory (file-name-directory file))
                        (write-region "" nil file nil 'silent)
                        file)))
         (left (or (dirdiff--local-file node 'left) absent))
         (right (or (dirdiff--local-file node 'right) absent))
         (buffer (current-buffer))
         (config (current-window-configuration))
         (session dirdiff--session)
         (ediff-diff-options
          (string-trim (concat ediff-diff-options
                               (and (dirdiff-session-ignore-whitespace session) " -w")
                               (and (dirdiff-session-ignore-line-endings session)
                                    " --strip-trailing-cr"))))
         (after-quit
          (lambda ()
            (set-window-configuration config)
            (dirdiff--save-after-ediff
             session (and (dirdiff-node-left node) left) (and (dirdiff-node-right node) right))
            (when absent
              (when-let* ((b (get-file-buffer absent)))
                (kill-buffer b))
              (delete-directory absent-dir t))
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (dirdiff--refresh-node dirdiff--session node)
                (dirdiff--render))))))
    (ediff-files left right
                 (list (lambda ()
                         (when-let* ((b (and absent (get-file-buffer absent))))
                           (with-current-buffer b (setq buffer-read-only t)))
                         ;; ediff ignores the global value of this hook
                         ;; once it has a local one, so include it.
                         (setq-local ediff-after-quit-hook-internal
                                     (append (remq t (default-value
                                                      'ediff-after-quit-hook-internal))
                                             (list after-quit))))))))

(defun dirdiff--save-after-ediff (session left right)
  "Save the changed buffers of files LEFT and RIGHT of SESSION.
Do what `dirdiff-save-after-ediff' says; nil files are skipped, and
so are files that cannot be changed on their side."
  (let ((buffers (cl-loop for (side file) in `((left ,left) (right ,right))
                          for source = (dirdiff--session-source session side)
                          for buffer = (and file
                                            (pcase (dirdiff-source-writable source)
                                              ('working-tree
                                               (dirdiff--working-tree-file
                                                source (file-relative-name
                                                        file (dirdiff-dir-source-root source))))
                                              (writable writable))
                                            (get-file-buffer file))
                          when (and buffer (buffer-modified-p buffer))
                          collect buffer)))
    (when (and buffers dirdiff-save-after-ediff)
      (save-some-buffers (not (eq dirdiff-save-after-ediff 'ask))
                         (lambda () (memq (current-buffer) buffers))))))

(defun dirdiff-open ()
  "Diff the files on the current row, or expand/collapse the directory.
A file that exists on one side only is diffed with an empty file."
  (interactive)
  (let* ((node (dirdiff--node-at-point))
         (l (dirdiff-node-left node))
         (r (dirdiff-node-right node)))
    (cond
     ((dirdiff--node-dir-p node)
      (dirdiff--set-open node (not (dirdiff--open-p node)))
      (dirdiff--render))
     (t
      (let* ((types (mapcar #'dirdiff-entry-type (delq nil (list l r))))
             (what (cond ((memq 'module types) "Submodule")
                         ((memq 'link types) "Symbolic link")
                         ((cl-some (lambda (side)
                                     (when-let* ((file (dirdiff--local-file node side)))
                                       (dirdiff--binary-file-p file)))
                                   '(left right))
                          "Binary file"))))
        (cond
         (what
          (message "%s" (pcase (dirdiff-node-status node)
                          ('same (format "%ss are identical" what))
                          ('left (format "%s on the left only" what))
                          ('right (format "%s on the right only" what))
                          (_ (format "%ss are different" what)))))
         ;; git also reports changes of the executable bit.
         ((and (eq (dirdiff-node-status node) 'changed)
               (dirdiff--equal-p (dirdiff--local-file node 'left)
                                 (dirdiff--local-file node 'right)
                                 (list (dirdiff-entry-size l) (dirdiff-entry-size r))
                                 "cmp" '("-s") #'identity))
          (message "The contents are identical; only the file mode differs (%s)"
                   (if (dirdiff--executable-p r)
                       "executable on the right"
                     "executable on the left")))
         (t (dirdiff--ediff node))))))))

(defun dirdiff--executable-p (entry)
  "Non-nil if ENTRY is an executable file."
  (if (dirdiff-entry-mode entry)
      (equal (dirdiff-entry-mode entry) "100755")
    (and (dirdiff-entry-file entry)
         (file-executable-p (dirdiff-entry-file entry))
         t)))

(defun dirdiff-mouse-open (event)
  "Open the entry clicked on with EVENT, like `dirdiff-open'."
  (interactive "e")
  (dirdiff-mouse-select event)
  (dirdiff-open))

(defun dirdiff--visit (find-file)
  "Call FIND-FILE on the entry at point, on the active side if it exists there."
  (let* ((node (dirdiff--node-at-point))
         (side (if (dirdiff--node-entry node dirdiff--side)
                   dirdiff--side
                 (dirdiff--other-side dirdiff--side))))
    (funcall find-file (dirdiff--local-file node side))))

(defun dirdiff-find-file ()
  "Visit the file or directory on the active side in this window.
If it only exists on the other side, visit that."
  (interactive)
  (dirdiff--visit #'find-file))

(defun dirdiff-find-file-other-window ()
  "Visit the file or directory on the active side in another window.
If it only exists on the other side, visit that."
  (interactive)
  (dirdiff--visit #'find-file-other-window))

(defun dirdiff-copy-filename-as-kill (&optional arg)
  "Copy the name of the entry at point into the kill ring, like Dired.
With no prefix ARG, copy the name without its directory.  With a
zero prefix (\\`C-0 w'), copy the full name on the active side, or
on the other side if it only exists there; for a git revision that
is REV:PATH.  With any other prefix, copy the name relative to the
compared directories."
  (interactive "P")
  (let* ((node (dirdiff--node-at-point))
         (side (if (dirdiff--node-entry node dirdiff--side)
                   dirdiff--side
                 (dirdiff--other-side dirdiff--side)))
         (name (cond ((eq arg 0)
                      (dirdiff-source-name (dirdiff--session-source dirdiff--session side)
                                           (dirdiff-node-rel node)))
                     (arg (dirdiff-node-rel node))
                     (t (dirdiff-node-name node)))))
    (kill-new name)
    (message "%s" name)))

;;;; Commands: editing

(defun dirdiff--writable-path (node side)
  "Return the local file name of NODE on SIDE, or signal an error."
  (let ((source (dirdiff--session-source dirdiff--session side)))
    (unless (dirdiff-source-writable source)
      (user-error "The %s side (%s) is read-only" side (dirdiff-source-label source)))
    (expand-file-name (dirdiff-node-rel node) (dirdiff-dir-source-root source))))

(defun dirdiff--working-tree-file (source rel)
  "Return the working tree file for REL in SOURCE, or nil.
SOURCE is git difftool's right side: its files are links into the
working tree, or copies that git copies back to it when the tool
exits.  Other files there are temporary, so changes to them are lost."
  (let ((file (expand-file-name rel (dirdiff-dir-source-root source))))
    (if (file-symlink-p file)
        (file-truename file)
      (and (dirdiff-dir-source-copies source)
           (gethash rel (dirdiff-dir-source-copies source))))))

(defun dirdiff--delete-local (file)
  "Delete FILE, or directory FILE with its contents.
Respects `delete-by-moving-to-trash'."
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
         (existing (dirdiff--node-entry node to))
         (source (dirdiff--session-source dirdiff--session to))
         (working-tree (and (eq (dirdiff-source-writable source) 'working-tree)
                            (or (and (eq (dirdiff-entry-type entry) 'file)
                                     existing (eq (dirdiff-entry-type existing) 'file)
                                     (dirdiff--working-tree-file source (dirdiff-node-rel node)))
                                (user-error "Only files from the working tree can be changed here")))))
    (when (dirdiff--confirm-copy node entry existing to dest working-tree)
      ;; Replace what is there, so that both sides end up identical
      ;; (a symlink is replaced, not written through), except where
      ;; writing into the working tree file is the point.
      (when (and existing (not working-tree))
        (dirdiff--delete-local dest))
      (make-directory (file-name-directory (directory-file-name dest)) t)
      (dirdiff-source-copy-to (dirdiff--session-source dirdiff--session from)
                              entry (dirdiff-node-rel node) dest)
      ;; The copy keeps the time of the original; with an old time and
      ;; the same size, git could take a copy for unchanged and not
      ;; copy it back to the working tree.
      (when working-tree
        (set-file-times dest))
      (dirdiff--refresh-node dirdiff--session node)
      (dirdiff--render))))

(defun dirdiff--confirm-copy (node entry existing to dest working-tree)
  "Ask whether to copy ENTRY of NODE to side TO, at local file DEST.
EXISTING is what is there now.  WORKING-TREE is the working tree file
that DEST changes, if any.  Replacing something asks with
`yes-or-no-p' and says what happens to the current version."
  (let ((name (concat (dirdiff-node-rel node) (if (dirdiff--entry-dir-p entry) "/" ""))))
    (cond
     ((not existing)
      (y-or-n-p (format "Copy %s to the %s side? " name to)))
     (working-tree
      (yes-or-no-p (format "Overwrite %s with the %s version%s? "
                           (abbreviate-file-name working-tree)
                           (dirdiff--other-side to)
                           (if (file-symlink-p dest) "" " (when you quit)"))))
     (t
      (yes-or-no-p (format (if delete-by-moving-to-trash
                               "Copy %s to the %s side, moving the %s there to the trash? "
                             "Copy %s to the %s side, deleting the %s there permanently? ")
                           name to
                           (if (dirdiff--entry-dir-p existing) "directory" "file")))))))

(defun dirdiff-copy-to-right ()
  "Copy the current file or directory from the left side to the right side."
  (interactive)
  (dirdiff--copy 'left))

(defun dirdiff-copy-to-left ()
  "Copy the current file or directory from the right side to the left side."
  (interactive)
  (dirdiff--copy 'right))

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
    (unless (eq (dirdiff-source-writable (dirdiff--session-source dirdiff--session side)) t)
      (user-error "Cannot delete on the %s side" side))
    (when (yes-or-no-p (format "Delete %s%s on the %s side? "
                               (dirdiff-node-rel node)
                               (if (dirdiff--entry-dir-p entry) "/ and its contents" "")
                               side))
      (dirdiff--delete-local file)
      (dirdiff--refresh-node dirdiff--session node)
      (dirdiff--render))))

(defun dirdiff-quit ()
  "Quit the comparison and kill its buffer.
If the comparison has its own frame, delete it.  If it replaced two
Dired windows, restore them (see `dirdiff-replace-dired-windows')."
  (interactive)
  (let ((config dirdiff--window-configuration))
    (quit-window t)
    (when config
      (set-window-configuration config))))

;;;; Mode

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
    ("v" "Visit" dirdiff-find-file)
    ("o" "Visit in other window" dirdiff-find-file-other-window)
    ("w" "Copy file name" dirdiff-copy-filename-as-kill)]]
  [["Show and compare"
    ("=" "Hide identical (toggle)" dirdiff-toggle-hide-identical :transient t)
    ("s" "Ignore whitespace (toggle)" dirdiff-toggle-ignore-whitespace :transient t)
    ("e" "Ignore line endings (toggle)" dirdiff-toggle-ignore-line-endings :transient t)
    ("x" "Ignore executable bit (toggle)" dirdiff-toggle-ignore-modes :transient t)
    ("B" "Binary files: full/quick (toggle)" dirdiff-toggle-binary-comparison :transient t)
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
  "RET" #'dirdiff-open
  "<mouse-1>" #'dirdiff-mouse-select
  "<double-mouse-1>" #'dirdiff-mouse-open
  "<mouse-2>" #'dirdiff-mouse-open
  "v" #'dirdiff-find-file
  "o" #'dirdiff-find-file-other-window
  "n" #'dirdiff-next-difference
  "p" #'dirdiff-previous-difference
  "^" #'dirdiff-up
  "+" #'dirdiff-expand-all
  "-" #'dirdiff-collapse-all
  "*" #'dirdiff-expand-changed
  "=" #'dirdiff-toggle-hide-identical
  "w" #'dirdiff-copy-filename-as-kill
  "s" #'dirdiff-toggle-ignore-whitespace
  "e" #'dirdiff-toggle-ignore-line-endings
  "x" #'dirdiff-toggle-ignore-modes
  "B" #'dirdiff-toggle-binary-comparison
  "g" #'dirdiff-refresh
  "!" #'dirdiff-refresh
  ">" #'dirdiff-copy-to-right
  "<" #'dirdiff-copy-to-left
  "M-<right>" #'dirdiff-copy-to-right
  "M-<left>" #'dirdiff-copy-to-left
  "a" #'dirdiff-copy-to-right
  "b" #'dirdiff-copy-to-left
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
    ["Visit" dirdiff-find-file]
    ["Visit in other window" dirdiff-find-file-other-window]
    ["Copy file name" dirdiff-copy-filename-as-kill]
    "---"
    ["Expand all" dirdiff-expand-all]
    ["Collapse all" dirdiff-collapse-all]
    ["Expand changed" dirdiff-expand-changed]
    "---"
    ["Hide identical" dirdiff-toggle-hide-identical
     :style toggle :selected (dirdiff-session-hide-identical dirdiff--session)]
    ["Ignore whitespace" dirdiff-toggle-ignore-whitespace
     :style toggle :selected (dirdiff-session-ignore-whitespace dirdiff--session)]
    ["Ignore line endings" dirdiff-toggle-ignore-line-endings
     :style toggle :selected (dirdiff-session-ignore-line-endings dirdiff--session)]
    ["Ignore executable bit" dirdiff-toggle-ignore-modes
     :style toggle :selected (dirdiff-session-ignore-modes dirdiff--session)]
    ["Compare binary files byte by byte" dirdiff-toggle-binary-comparison
     :style toggle :selected (eq (dirdiff-session-binary-comparison dirdiff--session) 'full)]
    ["Refresh" dirdiff-refresh]
    "---"
    ["Copy left to right" dirdiff-copy-to-right]
    ["Copy right to left" dirdiff-copy-to-left]
    ["Delete on active side" dirdiff-delete]
    "---"
    ["Quit" dirdiff-quit]))

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
  (setq-local mode-line-process '(:eval (dirdiff--mode-line)))
  (header-line-indent-mode 1)
  (setq header-line-format '("" header-line-indent (:eval (dirdiff--header-line))))
  (add-hook 'post-command-hook #'dirdiff--post-command nil t)
  (add-hook 'window-size-change-functions #'dirdiff--window-size-change nil t)
  (add-hook 'kill-buffer-hook #'dirdiff--cleanup nil t))

(defun dirdiff--cleanup (&optional session)
  "Run the cleanup functions of SESSION (default: the current one), once."
  (when-let* ((session (or session dirdiff--session)))
    (let ((functions (dirdiff-session-cleanup session)))
      (setf (dirdiff-session-cleanup session) nil)
      (mapc #'funcall functions))))

(defun dirdiff--new-frame-p ()
  "Non-nil if a comparison started now gets a new frame."
  (if (eq dirdiff-new-frame 'magit)
      (derived-mode-p 'magit-mode)
    dirdiff-new-frame))

(defun dirdiff--dired-window (dir)
  "Return a window of the selected frame showing DIR in Dired, or nil."
  (let ((dir (file-truename (file-name-as-directory dir))))
    (cl-find-if (lambda (window)
                  (with-current-buffer (window-buffer window)
                    (and (derived-mode-p 'dired-mode)
                         (equal (file-truename default-directory) dir))))
                (window-list nil 'no-minibuf))))

(defun dirdiff--replace-dired-windows (left right)
  "Make room for comparing LEFT and RIGHT where they are shown in Dired.
If both directories are shown in Dired windows, delete the right one,
so that the left one takes its space, and select the left one.
Return the window configuration from before, or nil if nothing was
done.  See `dirdiff-replace-dired-windows'."
  (let ((left-window (dirdiff--dired-window left))
        (right-window (dirdiff--dired-window right)))
    (when (and dirdiff-replace-dired-windows
               left-window right-window (not (eq left-window right-window))
               (not (dirdiff--new-frame-p)))
      (prog1 (current-window-configuration)
        (delete-window right-window)
        (select-window left-window)))))

(defun dirdiff-show-session (session &optional buffer-name)
  "Compare the sides of SESSION and display the result.
BUFFER-NAME defaults to one made from the side labels.  Return the buffer."
  (let ((new-frame (dirdiff--new-frame-p))
        (buffer (generate-new-buffer
                 (or buffer-name
                     (format "*dirdiff %s ↔ %s*"
                             (dirdiff-source-label (dirdiff-session-left session))
                             (dirdiff-source-label (dirdiff-session-right session)))))))
    (condition-case err
        (dirdiff--build-tree session)
      ((error quit)
       (kill-buffer buffer)
       (dirdiff--cleanup session)
       (signal (car err) (cdr err))))
    (let ((pred (pcase dirdiff-initial-expansion
                  ('all #'always)
                  ('none #'ignore)
                  (_ #'dirdiff--changed-dir-p))))
      (dirdiff--walk (dirdiff-session-tree session)
                     (lambda (node)
                       (when (and (dirdiff--node-dir-p node) (funcall pred node))
                         (puthash (dirdiff-node-rel node) t (dirdiff-session-open session))))))
    ;; `quit-window' deletes a frame that `display-buffer' made.
    (pop-to-buffer buffer (if new-frame
                              `((display-buffer-pop-up-frame)
                                (pop-up-frame-parameters . ,dirdiff-frame-parameters))
                            '((display-buffer-same-window))))
    (dirdiff-mode)
    (setq dirdiff--session session)
    (dirdiff--render)
    (goto-char (point-min))
    (dirdiff--place)
    (message "%s.  %s" (capitalize (dirdiff--summary session))
             (substitute-command-keys "\\<dirdiff-mode-map>\\[dirdiff-dispatch] for commands"))
    buffer))

;;;; Entry points

(defun dirdiff--dired-marked-p ()
  "Non-nil if the current Dired buffer has marked files."
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
      ;; No default: with one (such as the file at point in Dired),
      ;; completion UIs like vertico preselect a candidate, and RET
      ;; takes that instead of the directory shown in the prompt.
      (let* ((a (read-file-name "Left file or directory: " nil nil t))
             (other (and (derived-mode-p 'dired-mode)
                         (progn (require 'dired-aux) (dired-dwim-target-directory))))
             (b (read-file-name (format "Compare %s with: " (abbreviate-file-name a))
                                other nil t)))
        (list a b)))))

(defun dirdiff--dir-source (dir &optional writable)
  "Return a directory source for DIR; WRITABLE as in `dirdiff-source'."
  (dirdiff-dir-source-create :root (file-name-as-directory (expand-file-name dir))
                             :label (abbreviate-file-name dir)
                             :writable writable))

;;;###autoload
(defun dirdiff (left right)
  "Compare LEFT and RIGHT: two directories side by side, two files with ediff.
In Dired with exactly two marked entries, those are compared.  When
both directories are shown in Dired windows, the comparison replaces
them until it is quit (see `dirdiff-replace-dired-windows')."
  (interactive (dirdiff--read-paths))
  (cond ((and (file-directory-p left) (file-directory-p right))
         (let* ((config (dirdiff--replace-dired-windows left right))
                (buffer (dirdiff-show-session
                         (dirdiff-session-create :left (dirdiff--dir-source left t)
                                                 :right (dirdiff--dir-source right t)))))
           (with-current-buffer buffer
             (setq dirdiff--window-configuration config))
           buffer))
        ((not (or (file-directory-p left) (file-directory-p right)))
         (ediff-files left right))
        (t (user-error "Cannot compare a file with a directory"))))

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
    (dirdiff (car dirs) (cadr dirs))))

;;;###autoload
(defun dirdiff-command-line ()
  "Compare the next two command line arguments, then exit Emacs.
For starting dirdiff from a shell, like meld:

  `emacs -f dirdiff-command-line LEFT RIGHT'

Directories are compared side by side and files with ediff.  Emacs
exits when the comparison is quit, asking to save changed files.
Return the dirdiff buffer, or nil for files."
  (pcase-let ((`(,left ,right) (dirdiff--command-line-args 'dirdiff-command-line))
              (dirdiff-new-frame nil))
    (if (and (file-directory-p left) (file-directory-p right))
        (dirdiff--exit-with (dirdiff left right))
      (add-hook 'ediff-quit-hook #'dirdiff--exit 90)
      (dirdiff left right))))

;;;###autoload
(defun dirdiff-difftool-command-line ()
  "Compare `git difftool --dir-diff's two directories, then exit Emacs.
They are the next two command line arguments.  In the git config,
set difftool.dirdiff.cmd to:

  emacs -f dirdiff-difftool-command-line \"$LOCAL\" \"$REMOTE\"

Unlike with `dirdiff-command-line', the left side is read-only, and
on the right side files of the working tree can be changed but not
added or deleted.  Return the dirdiff buffer."
  (pcase-let ((`(,left ,right) (dirdiff--command-line-args 'dirdiff-difftool-command-line))
              (dirdiff-new-frame nil))
    (dirdiff--exit-with (dirdiff-show-session (dirdiff--difftool-session left right)))))

(defun dirdiff--command-line-args (function)
  "Remove two file names from the command line arguments; return them.
FUNCTION is the function run with -f, for the error message."
  (unless (cdr command-line-args-left)
    (error "Give two files or directories after -f %s" function))
  (list (expand-file-name (pop command-line-args-left) command-line-default-directory)
        (expand-file-name (pop command-line-args-left) command-line-default-directory)))

(defun dirdiff--exit ()
  "Exit Emacs soon, asking to save changed files."
  (run-at-time 0 nil #'save-buffers-kill-emacs))

(defun dirdiff--exit-with (buffer)
  "Exit Emacs when BUFFER is killed; return BUFFER."
  (with-current-buffer buffer
    (add-hook 'kill-buffer-hook #'dirdiff--exit nil t))
  buffer)

(defun dirdiff--difftool-session (left right)
  "Return a session for git difftool's directories LEFT and RIGHT.
LEFT is a temporary snapshot, so it is read-only.  On the right side,
only the files that git took from the working tree can be changed,
which changes the working tree: git links to them, or copies them and
copies changes back when the tool exits (with core.symlinks false, as
on Windows)."
  (let* ((files (directory-files-recursively right ""))
         (links (cl-some #'file-symlink-p files))
         (copies (unless links (dirdiff--difftool-copies right files)))
         (source (dirdiff--dir-source
                  right (and (or links (> (hash-table-count copies) 0)) 'working-tree))))
    (setf (dirdiff-dir-source-copies source) copies)
    (dirdiff-session-create :left (dirdiff--dir-source left) :right source
                            :hide-identical t)))

(defun dirdiff--difftool-copies (right files)
  "Return a table of the FILES in RIGHT that git copied from the working tree.
It maps their relative names to the working tree files.  git copies
a file when it is the same as in the working tree; the working tree
is in $GIT_WORK_TREE, which git sets for the tool."
  (let ((table (make-hash-table :test #'equal))
        (worktree (getenv "GIT_WORK_TREE")))
    (when worktree
      (dolist (file files)
        (let* ((rel (file-relative-name file right))
               (wt (expand-file-name rel worktree)))
          (when (and (file-regular-p wt)
                     (eql (file-attribute-size (file-attributes file))
                          (file-attribute-size (file-attributes wt)))
                     (string= (dirdiff--read-bytes file) (dirdiff--read-bytes wt)))
            (puthash rel wt table)))))
    table))

(provide 'dirdiff)
;;; dirdiff.el ends here
