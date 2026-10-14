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
;; If you already add suffixes with these keys (for example from a
;; magit-difftool.el), remove those first, or use other keys below.

;;; Code:

;; Where dirdiff lives.  Not needed once dirdiff is installed as a package.
(add-to-list 'load-path "/home/common/ws/emacs/emacs-dirdiff")

(autoload 'dirdiff "dirdiff" nil t)
(autoload 'dirdiff-dired "dirdiff" nil t)
(autoload 'dirdiff-git "dirdiff-git" nil t)
(autoload 'dirdiff-git-commit "dirdiff-git" nil t)
(autoload 'dirdiff-git-head "dirdiff-git" nil t)
(autoload 'dirdiff-git-worktree "dirdiff-git" nil t)
(autoload 'dirdiff-git-status "dirdiff-git" nil t)

;;;; Option 1: the default keys (D p, D h, D w)

(with-eval-after-load 'magit-diff
  (require 'dirdiff-git)
  (dirdiff-magit-setup))

;;;; Option 2: choose your own keys and descriptions
;;
;; Use this instead of option 1.  `(-1 -1 -1)' appends after the last
;; suffix of the last group, the same place `dirdiff-magit-setup' uses.

;; (with-eval-after-load 'magit-diff
;;   (transient-append-suffix 'magit-diff '(-1 -1 -1)
;;     '("D d" "Dirdiff range or commit" dirdiff-git))
;;   (transient-append-suffix 'magit-diff '(-1 -1 -1)
;;     '("D c" "Dirdiff commit vs its parent" dirdiff-git-commit))
;;   (transient-append-suffix 'magit-diff '(-1 -1 -1)
;;     '("D h" "Dirdiff against HEAD" dirdiff-git-head))
;;   (transient-append-suffix 'magit-diff '(-1 -1 -1)
;;     '("D w" "Dirdiff against working tree" dirdiff-git-worktree))
;;   (transient-append-suffix 'magit-diff '(-1 -1 -1)
;;     '("D s" "Dirdiff HEAD vs working tree" dirdiff-git-status)))

;;;; Optional extras

;; `D' in vc log buffers (C-x v l): the revision at point vs its parent,
;; or the oldest vs the newest revision in the region.
(with-eval-after-load 'log-view
  (require 'dirdiff-git)
  (dirdiff-vc-setup))

;; Compare the two directories marked in the visible Dired windows.
;; (with-eval-after-load 'dired
;;   (keymap-set dired-mode-map "C-c =" #'dirdiff-dired))

;;; dirdiff-magit-config.el ends here
