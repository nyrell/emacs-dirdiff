# Best practices

Condensed from the Elisp manual's *Tips and Conventions* appendix and from
what `package-lint` and `checkdoc` enforce. Skeletons are in
[templates.md](templates.md).

## Files

- First line: `;;; name.el --- Summary  -*- lexical-binding: t; -*-`.
  Without `lexical-binding`, closures silently do not work, and Emacs 30
  warns about it.
- Headers `;; Author:`, `;; Version:`, `;; Package-Requires: ((emacs "29.1"))`,
  `;; URL:`, then `;;; Commentary:`, `;;; Code:`, and finally
  `(provide 'name)` and `;;; name.el ends here`.
- `Package-Requires` must name the oldest Emacs you support, and you must not
  use anything newer. For ways to check, see
  [verification.md](verification.md#which-emacs-version-has-it).
- Put closing parentheses on the last line of a form, never alone on a line.
  Use Emacs's indentation (`emacs-for-agents/tools/elisp-agent indent --fix FILE`).

## Naming

- Every global symbol starts with the package prefix: `mypkg-`. Internal
  ones use a double hyphen: `mypkg--helper`. Code in other packages or in
  user configuration must not call `--` symbols; make such commands public.
- Predicates end in `-p` (`mypkg-ready-p`). Variables holding a function end
  in `-function`, hooks in `-hook` or `-functions`.
- Do not use `path` for file names (it means a search path in Emacs); use
  `file`, `file-name` or `directory`.

## Loading

- **Loading a file must not change Emacs's behavior.** No global key
  bindings, no `add-hook` to global hooks, no turning on modes, no
  `setq` of other packages' variables at top level. Provide commands or a
  minor mode the user turns on.
- `require` what you use at top level. Use `(declare-function f "lib")` and
  `(defvar some-var)` to silence the compiler for optional dependencies that
  you load only when needed, with `require` inside the function. For a
  package that is not part of Emacs, write `"ext:lib"`; `check` verifies
  these declarations.
- `(require 'cl-lib)` and the `cl-` names (`cl-loop`, `cl-incf`,
  `cl-flet`), never the obsolete `cl` library or its unprefixed names
  (`loop`, `incf`, `flet`, `lexical-let`): models trained on old code
  still write them.
- `;;;###autoload` on commands users call, so the package needn't be loaded
  until then.
- `with-eval-after-load` is for user configuration, not for libraries. A
  library's setup function can `require` what it extends and let the user
  call it from `with-eval-after-load` in their init file.
- Never redefine or advise primitives or functions of other packages.

## Variables

- User options are `defcustom` with a `:type` (and `:group` or a preceding
  `defgroup`). Internal state is `defvar` / `defvar-local`; constants are
  `defconst`.
- Per-buffer state: `defvar-local`. Do not `make-local-variable` inside a
  function when `defvar-local` would do.
- **Before let-binding a variable from another library, `require` it.** If
  the library is not loaded yet, the `let` is lexical and has no effect.
  See [pitfalls.md](pitfalls.md).

## Data

- Compare with the right predicate: `eq` for symbols and identity,
  `eql` for numbers, `equal` for strings, lists and other structure,
  `string=` for strings when you want to say so. `(eq "a" "a")` is nil.
  `memq`/`assq` use `eq`; `member`/`assoc` use `equal`.
- `sort`, `nconc`, `nreverse`, `delete` and `delq` may change their
  argument. Always use the return value (`(setq l (sort l #'<))`), and
  never apply them to a quoted constant like `'(3 1 2)`: copy it, or
  build it with `list`.
- Alists: `alist-get` (with `setf` to change one); plists: `plist-get`;
  many lookups: a hash table with `:test #'equal` for string keys.

## Functions and commands

- Every function and variable has a docstring. The first line is a complete
  sentence of at most about 80 characters. Arguments are mentioned in
  CAPITALS. Commands describe what they do from the user's view.
- `(interactive ...)` with a spec or a list of `read-…` calls; use
  `format-prompt` for prompts with defaults; `user-error` for mistakes the
  user made (no backtrace) and `error` for bugs.
- Errors and `message`s start with a capital letter and do not end with a
  period. `y-or-n-p` and `yes-or-no-p` prompts end with a question mark and a
  space. Destructive actions on several files or directories ask with
  `yes-or-no-p`, and say what will happen.
- Quote functions with `#'` (`(mapcar #'car list)`) so the compiler checks
  that they exist. Name unused arguments with a leading underscore
  (`_event`). Use `dolist` or `mapc`, not `mapcar`, when only side effects
  matter.
- Add **named functions** to hooks, not lambdas: a lambda cannot be removed
  again with `remove-hook`. Whatever a mode adds (hooks, advice, timers),
  it removes when it is turned off.
- Keep functions short and give each one job. Prefer `let`, `when`,
  `unless`, `cond`, `dolist`, `pcase` with simple patterns; reach for
  `cl-loop` only when it is clearly shorter.

## Modes

- Major modes: `define-derived-mode`. Read-only display buffers derive from
  `special-mode` (gives `q`, `g`, read-only); tables from
  `tabulated-list-mode`. Set `revert-buffer-function` so `g` refreshes.
- Minor modes: `define-minor-mode` (with `:global t` for global ones).
- Add hooks buffer-locally inside a mode: `(add-hook 'post-command-hook #'f nil t)`.
- Keymaps: `defvar-keymap` and `keymap-set` (Emacs 29). Major modes may bind
  plain keys only in read-only buffers; `C-c LETTER` and F5–F9 are reserved
  for users, so never bind them in a package.

## Buffers, windows, frames

- `with-current-buffer` and `with-temp-buffer` instead of `set-buffer`;
  `save-excursion` to preserve point.
- Show buffers with `display-buffer`, `pop-to-buffer` or
  `pop-to-buffer-same-window` and an action alist. Do not split windows
  yourself; users configure `display-buffer-alist`. `quit-window` undoes
  what `display-buffer` did, including deleting a frame it made.
- Respect the user's configuration: if you add a buffer-local value to a hook
  that Emacs runs with only the local value (like
  `ediff-after-quit-hook-internal`), include the global value too.

## Regular expressions

Emacs regexps are not Perl's. Models trained mostly on other languages
write Perl syntax that silently matches something else.

| Perl habit | Emacs | Note |
|---|---|---|
| `\d` | `[0-9]` or `[[:digit:]]` | `\d` matches the letter `d` |
| `\s` for whitespace | `[[:space:]]` or `\s-` | `\s` is a syntax-class prefix |
| `(a\|b)`, `(?:...)` | `\(a\|b\)`, `\(?:...\)` | Plain parentheses are literal |
| `^`, `$` for the whole string | `` \` ``, `\'` | `^` and `$` match at every newline |
| `"\."` in a string | `"\\."` | Lisp strings need the backslash doubled |

- Searches and `string-match` ignore case unless you bind
  `case-fold-search` to nil: `(let ((case-fold-search nil)) ...)`.
- Use `regexp-quote` for literal text, and `rx` for anything long:
  `(rx bos (+ digit) "." (+ digit) eos)` is hard to get wrong.
- `string-match` and `re-search-forward` change the match data; use
  `string-match-p` when you only test, and `save-match-data` in functions
  that others call between a match and `match-string`.
- `emacs-for-agents/tools/elisp-agent check --regexp` runs relint, which finds most of these.

## Files and processes

- Build file names with `expand-file-name` and `file-name-concat`, not
  `concat` with "/". Use `abbreviate-file-name` for display.
- Run programs with `call-process` / `process-file` (synchronous) or
  `make-process` (asynchronous) and **pass arguments as a list**. Never build
  a shell command string from file names; if you must, use
  `shell-quote-argument`. Check the exit status.
- Read binary data with `insert-file-contents-literally` in a unibyte
  buffer; bind `coding-system-for-read` / `-write` for process I/O.
- `process-file` works on remote (TRAMP) directories, `call-process` does not.

## Errors

- `condition-case` around the smallest form that can fail, catching the
  narrowest error symbol (`file-error`, `scan-error`), never a bare
  `ignore-errors` around a large body.
- Clean up with `unwind-protect` (temporary files, processes, buffers).

## Checklist before committing

```sh
T=emacs-for-agents/tools/elisp-agent
$T -L . check --doc *.el     # structure, zero warnings, declarations, checkdoc
$T indent *.el               # standard indentation
$T -L . test test/*-test.el  # tests
# Regexps: needs relint, from the user's packages or your own directory
# (verification.md, step 4), e.g.:
ELISP_AGENT_PACKAGE_DIR=$D $T --packages -L . check --regexp *.el
# MELPA: package-lint (verification.md, step 4)
```
