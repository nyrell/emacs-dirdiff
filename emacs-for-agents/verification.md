# Verifying that the code works

Climb the ladder in order; each step is slower but catches things the
previous one cannot. Do not report something as working until it has passed
the steps that apply. `$T` is `emacs-for-agents/tools/elisp-agent`, run from
the project root.

| # | Step | Catches | How |
|---|---|---|---|
| 0 | Structure | Missing or extra parens | `$T check` |
| 1 | Byte-compile | Unknown functions, missing `require`, wrong arity, free variables | `$T -L . check` (zero warnings) |
| 2 | Load in `emacs -Q` | Missing `require`, load-time errors | `emacs --batch -Q -L . --eval "(require 'mypkg)"` |
| 3 | Unit tests | Wrong results | `$T -L . test` (see [testing.md](testing.md)) |
| 4 | Lint | Docstrings, headers, naming, MELPA rules, regexps, Emacs version | `$T check --doc --regexp`, `$T indent`, package-lint |
| 5 | Command loop in batch | Hooks, keymaps, real key sequences | `execute-kbd-macro` |
| 6 | Live Emacs | Display, windows, frames, interaction with the user's setup | `emacsclient --eval` |
| 7 | Screenshot | What it actually looks like | `x-export-frames` |

## 2. Load in a clean Emacs

`-Q` skips the user's init file, so a missing `require` shows up here and
not later on someone else's machine. Load with the dependencies the package
declares and nothing else.

## 4. Linters without touching the user's config

**Never change the user's Emacs configuration**: no installing packages
into `~/.emacs.d`, no edits to `init.el` or the custom file. Reading it is
fine: `$T --packages` uses packages the user has installed. If package-lint
or relint is missing, install it into a directory of your own:

```sh
D=$(mktemp -d)
emacs --batch -Q --eval "(progn (setq package-user-dir \"$D\") (package-initialize)
  (add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\"))
  (package-refresh-contents) (package-install 'package-lint) (package-install 'relint))"
emacs --batch -Q --eval "(progn (setq package-user-dir \"$D\") (package-initialize) (require 'package-lint))" \
  -L . --eval '(setq package-lint-main-file "mypkg.el")' -f package-lint-batch-and-exit *.el
ELISP_AGENT_PACKAGE_DIR=$D emacs-for-agents/tools/elisp-agent --packages -L . check --regexp *.el
```

## Which Emacs version has it?

Code must not use anything newer than the Emacs in `Package-Requires`.
There are several ways to find out; use more than one when it matters:

- `$T describe NAME` prints the first NEWS heading that mentions it, e.g.
  `first in NEWS: Emacs 28: ** New function 'string-pad'.` That is
  usually when it appeared (a heading can also be about a change).
- package-lint (step 4) reports uses of functions and variables newer than
  the package's declared minimum: "You should depend on (emacs "28.1") or
  the compat package if you need `string-pad'".
- The manual and NEWS: `$T info --search elisp NAME`, or search the NEWS
  files directly: `grep -n "NAME" $(emacs --batch -Q --eval '(princ data-directory)')/NEWS*`.
- Run the checks with the older Emacs, if it is installed:
  `EMACS=emacs-29 $T -L . check *.el`, then `test`.

## 5. Real key sequences in batch

Calling a command as a function skips `post-command-hook`, the keymap and
the interactive spec. `execute-kbd-macro` goes through the command loop:

```elisp
(with-current-buffer buf
  (execute-kbd-macro (kbd "TAB n C-a"))
  (should (eq mypkg--side 'right)))
```

## 6. A live Emacs

If the user runs an Emacs server, `emacsclient --eval '(...)'` evaluates in
it and prints the result. It is the real environment: the user's theme,
packages, display and window manager. It is also **the user's working
session**. Rules:

- Load your code explicitly from the file you edited:
  `(load "/abs/path/mypkg.el" nil t)`. A `require` does nothing if an older
  version is already loaded.
- Work in a frame of your own (`make-frame`), never in the user's windows,
  and delete it afterwards.
- Clean up every buffer, frame, hook and timer you create. List frames and
  buffers before and after.
- Expect the user's configuration to interact with yours (display-buffer
  rules, hooks that make frames, global modes such as line numbers).
  That is the point of this step; report what you find.
- Calls through `emacsclient --eval` also skip the command loop; use
  `execute-kbd-macro` inside the evaluated form for real key handling.
- Never change the user's configuration (see step 4).
- For anything disruptive, start a separate server: `emacs -Q --daemon=test`
  and `emacsclient -s test --eval ...`; stop it with `(kill-emacs)`.
- **The user may have the file open with unsaved changes.** Before writing
  a file from outside, check
  `(when-let* ((b (find-buffer-visiting "/abs/file.el"))) (buffer-modified-p b))`;
  if it is non-nil, ask instead of writing. After writing, refresh their
  buffer with `(with-current-buffer b (revert-buffer t t t))` so the
  buffer and the file agree.
- Run tests in batch, not here. `ert-run-tests-batch-and-exit` refuses
  outside batch, and tests that do run in a live Emacs leave their state
  behind (definitions, hooks, buffers). Some published skills tell agents
  to do *everything* through `emacsclient`; that is convenient but makes
  results depend on the user's session, and a crash or hang takes the
  user's Emacs with it.

## 7. Screenshots

With a Cairo build (`(featurep 'cairo)`), Emacs can render a frame to PNG,
which an agent that reads images can then inspect:

```elisp
(with-temp-file "/tmp/shot.png"
  (set-buffer-multibyte nil)
  (redisplay t)
  (insert (x-export-frames my-frame 'png)))
```

Use it to check layout, alignment, faces and highlights: things a test of
the buffer text cannot see.

## When something fails

- **Get the backtrace.** `$T eval` prints only the error. A
  plain batch run prints the whole call stack, which shows where it
  happened:

  ```
  $ emacs --batch -Q -L . -l mypkg --eval '(mypkg-outer)'
  Error: wrong-type-argument (listp 5)
    car(5)
    mypkg-inner(5)
    mypkg-outer()
  ```

- **Read the error symbol**, then look up the cause:

  | Error | Usual cause |
  |---|---|
  | `void-function foo` | Typo, invented function, its library is not loaded (`require`), or `(foo)` where `foo` is a variable holding a function (use `funcall`) |
  | `void-variable foo` | Typo, a missing `let`, or a quoted symbol written without `'` |
  | `wrong-number-of-arguments` | Check the signature with `describe` |
  | `wrong-type-argument listp 5` | A value of the wrong type; the predicate (`listp`) says what was expected |
  | `invalid-function ("a")` | A list without its quote: `("a" "b")` instead of `'("a" "b")`, or a non-function given to `funcall`/`mapcar` |
  | `end-of-file` / `scan-error` | Unbalanced parentheses or an unterminated string: run `check` |
  | `args-out-of-range` | A position or index outside the buffer, string or narrowing |

- **Trace calls** without editing the code: `(trace-function 'mypkg-f)`,
  then read the `*trace-output*` buffer (in batch:
  `(with-current-buffer "*trace-output*" (princ (buffer-string)))`).

## Always

- Use a timeout when running Emacs from a shell (`timeout 60 emacs --batch …`).
  A hang in batch looks the same as slow work.
- Read the output; do not just check the exit code. A plain ERT run that
  loaded zero tests also "passes" (`$T test` fails then).
- Report honestly what was verified and what was not, e.g. "tested on Emacs
  30.1 only".
