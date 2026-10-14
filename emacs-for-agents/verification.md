# Verifying that the code works

Climb the ladder in order; each step is slower but catches things the
previous one cannot. Do not report something as working until it has passed
the steps that apply.

| # | Step | Catches | How |
|---|---|---|---|
| 0 | Structure | Missing or extra parens | `elisp-agent check` |
| 1 | Byte-compile | Unknown functions, wrong arity, free variables, typos | `elisp-agent check` (zero warnings) |
| 2 | Load in `emacs -Q` | Missing `require`, load-time errors | `emacs --batch -Q -L . --eval "(require 'mypkg)"` |
| 3 | Unit tests | Wrong results | `elisp-agent test` (see [testing.md](testing.md)) |
| 4 | Lint | Docstrings, headers, naming, MELPA rules, regexps | `check --doc --regexp`, `indent`, package-lint |
| 5 | Command loop in batch | Hooks, keymaps, real key sequences | `execute-kbd-macro` |
| 6 | Live Emacs | Display, windows, frames, interaction with the user's setup | `emacsclient --eval` |
| 7 | Screenshot | What it actually looks like | `x-export-frames` |

## 2. Load in a clean Emacs

`-Q` skips the user's init file, so a missing `require` shows up here and
not later on someone else's machine. Load with the dependencies the package
declares and nothing else.

## 4. Linters without touching the user's packages

Install package-lint (MELPA) and relint (GNU ELPA) into a directory of
your own, never into the user's `~/.emacs.d`:

```sh
D=$(mktemp -d)
emacs --batch -Q --eval "(progn (setq package-user-dir \"$D\") (package-initialize)
  (add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\"))
  (package-refresh-contents) (package-install 'package-lint) (package-install 'relint))"
emacs --batch -Q --eval "(progn (setq package-user-dir \"$D\") (package-initialize) (require 'package-lint))" \
  -L . --eval '(setq package-lint-main-file "mypkg.el")' -f package-lint-batch-and-exit *.el
ELISP_AGENT_PACKAGE_DIR=$D elisp-agent --packages -L . check --regexp *.el
```

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

- **Get the backtrace.** `elisp-agent eval` prints only the error. A
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
- Read the output; do not just check the exit code. A test run that loaded
  zero tests also "passes".
- Report honestly what was verified and what was not, e.g. "tested on Emacs
  30.1 only".
