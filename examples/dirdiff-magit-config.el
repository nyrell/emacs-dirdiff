;;; dirdiff-magit-config.el --- Example: dirdiff in magit's diff menu  -*- lexical-binding: t; -*-

;;; Commentary:

;; Copy what you need into your init file, or load this file from it:
;;
;;   (load "/path/to/emacs-dirdiff/examples/dirdiff-magit-config.el")
;;
;; It adds dirdiff commands to magit's diff menu (`d' in magit buffers),
;; replacing `git difftool -d' suffixes such as:
;;
;;   D p   range or commit     (at a commit, suggests <commit>^..<commit>)
;;   D h   revision vs HEAD
;;   D w   revision vs working tree
;;
;; Comparisons started from magit open in a new, maximized frame and
;; `q' deletes it again; see the end of this file to change that.
;;
;; If you already add suffixes with these keys (for example from a
;; magit-difftool.el), remove those first, or use other keys below.

;;; Code:

;; Where dirdiff lives.  Not needed once dirdiff is installed as a package.
(add-to-list 'load-path "/home/common/ws/emacs/emacs-dirdiff")

(autoload 'dirdiff "dirdiff" nil t)
(autoload 'dirdiff-dired "dirdiff" nil t)
(autoload 'dirdiff-git "dirdiff-git" nil t)

;;;; Option 1: the default keys (D p, D h, D w)

(with-eval-after-load 'magit-diff
  (require 'dirdiff-git)
  (dirdiff-magit-setup))

;;;; Option 2: choose your own keys and descriptions
;;
;; Use this instead of option 1.  `(-1 -1 -1)' appends after the last
;; suffix of the last group, the same place `dirdiff-magit-setup' uses.
;; `dirdiff-git' takes a range like `git difftool -d': A..B, A...B,
;; C^! (a commit vs its parent) or A (vs the working tree).

;; (defun my/dirdiff-head-vs-worktree ()
;;   "Compare HEAD with the working tree."
;;   (interactive)
;;   (dirdiff-git "HEAD"))
;;
;; (with-eval-after-load 'magit-diff
;;   (require 'dirdiff-git)
;;   (transient-append-suffix 'magit-diff '(-1 -1 -1)
;;     '("D d" "Dirdiff range or commit" dirdiff-git))
;;   (transient-append-suffix 'magit-diff '(-1 -1 -1)
;;     '("D h" "Dirdiff against HEAD" dirdiff-git--against-head))
;;   (transient-append-suffix 'magit-diff '(-1 -1 -1)
;;     '("D w" "Dirdiff against working tree" dirdiff-git--against-worktree))
;;   (transient-append-suffix 'magit-diff '(-1 -1 -1)
;;     '("D s" "Dirdiff HEAD vs working tree" my/dirdiff-head-vs-worktree)))

;;;; Optional extras

;; Where comparisons are shown: `magit' (the default) uses a new frame
;; when started from magit, t always, nil never (the selected window).
;; (setq dirdiff-new-frame t)
;; New frames are maximized; to get a normal frame instead:
;; (setq dirdiff-frame-parameters nil)

;; `D' in vc log buffers (C-x v l): the revision at point vs its parent,
;; or the oldest vs the newest revision in the region.
(with-eval-after-load 'log-view
  (require 'dirdiff-git)
  (dirdiff-vc-setup))

;; Compare the two directories marked in the visible Dired windows.
;; (with-eval-after-load 'dired
;;   (keymap-set dired-mode-map "C-c =" #'dirdiff-dired))

;;; dirdiff-magit-config.el ends here
