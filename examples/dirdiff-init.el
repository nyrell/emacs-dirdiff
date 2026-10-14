;;; dirdiff-init.el --- Example: load dirdiff with the magit keys  -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything needed to use dirdiff, in one file.  Load it from your
;; init file (it finds the package next to itself, wherever you cloned
;; it):
;;
;;   (load "/path/to/emacs-dirdiff/examples/dirdiff-init.el")
;;
;; or try it in an Emacs without your init file, with your installed
;; packages (magit) from PACKAGE-DIR:
;;
;;   emacs -Q --eval '(setq package-user-dir "PACKAGE-DIR")' \
;;         -f package-initialize -l /path/to/emacs-dirdiff/examples/dirdiff-init.el
;;
;; It gives you:
;;
;;   M-x dirdiff         two files (ediff) or two directories
;;   M-x dirdiff-git     git revisions, like `git difftool -d'
;;   magit, d D p        range or commit (at a commit: <commit>^..<commit>)
;;   magit, d D h        revision vs HEAD
;;   magit, d D w        revision vs working tree
;;   vc log, D           revision at point vs its parent, or the region
;;   Dired, C-c =        the two directories marked in the visible windows
;;
;; Comparisons started from magit open in a new frame; `q' closes it.
;;
;; If `D p', `D h' or `D w' are already in magit's diff menu (for
;; example from a magit-difftool.el), they are replaced, whichever file
;; is loaded first.  To keep them and use other keys for dirdiff, see
;; option 2 in dirdiff-magit-config.el.

;;; Code:

(add-to-list 'load-path
             (file-name-directory
              (directory-file-name
               (file-name-directory (or load-file-name buffer-file-name)))))

(autoload 'dirdiff "dirdiff" nil t)
(autoload 'dirdiff-dired "dirdiff" nil t)
(autoload 'dirdiff-git "dirdiff-git" nil t)

(declare-function dirdiff-magit-setup "../dirdiff-git" ())
(declare-function dirdiff-vc-setup "../dirdiff-git" ())
(declare-function transient-get-suffix "ext:transient" (prefix loc))
(declare-function transient-remove-suffix "ext:transient" (prefix loc))
(defvar dired-mode-map)

(defun my/dirdiff-magit-setup ()
  "Put the dirdiff commands on \\`D p', \\`D h' and \\`D w' in magit's diff menu."
  (dolist (key '("D p" "D h" "D w"))
    (when (ignore-errors (transient-get-suffix 'magit-diff key))
      (transient-remove-suffix 'magit-diff key)))
  (dirdiff-magit-setup))

;; Magit: after the init file, so that keys added by other files loaded
;; later in it are replaced too.
(defun my/dirdiff-magit-setup-later ()
  "Set up the magit keys once magit's diff menu is loaded."
  (with-eval-after-load 'magit-diff
    (require 'dirdiff-git)
    (my/dirdiff-magit-setup)))

(if after-init-time
    (my/dirdiff-magit-setup-later)
  (add-hook 'after-init-hook #'my/dirdiff-magit-setup-later))

;; vc log buffers (C-x v l).
(with-eval-after-load 'log-view
  (require 'dirdiff-git)
  (dirdiff-vc-setup))

;; Dired.
(with-eval-after-load 'dired
  (keymap-set dired-mode-map "C-c =" #'dirdiff-dired))

;; Options; the values shown are the defaults.
;; (setq dirdiff-new-frame 'magit)          ; t: always a new frame, nil: never
;; (setq dirdiff-frame-parameters '((fullscreen . maximized))) ; nil: normal size
;; (setq dirdiff-hide-identical nil)        ; directories; git always starts hidden
;; (setq dirdiff-ignore-whitespace nil)
;; (setq dirdiff-binary-comparison 'quick)  ; `full': byte by byte

;;; dirdiff-init.el ends here
