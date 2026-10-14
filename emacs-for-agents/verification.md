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
| 4 | Lint | Docstrings, headers, naming, MELPA rules | `check --doc`, `indent`, package-lint |
| 5 | Command loop in batch | Hooks, keymaps, real key sequences | `execute-kbd-macro` |
| 6 | Live Emacs | Display, windows, frames, interaction with the user's setup | `emacsclient --eval` |
| 7 | Screenshot | What it actually looks like | `x-export-frames` |

## 2. Load in a clean Emacs

`-Q` skips the user's init file, so a missing `require` shows up here and
not later on someone else's machine. Load with the dependencies the package
declares and nothing else.

## 4. package-lint without touching the user's packages

```sh
D=$(mktemp -d)
emacs --batch -Q --eval "(progn (setq package-user-dir \"$D\") (package-initialize)
  (package-refresh-contents) (package-install 'package-lint))"
emacs --batch -Q --eval "(progn (setq package-user-dir \"$D\") (package-initialize) (require 'package-lint))" \
  -L . --eval '(setq package-lint-main-file "mypkg.el")' -f package-lint-batch-and-exit *.el
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

## Always

- Use a timeout when running Emacs from a shell (`timeout 60 emacs --batch …`).
  A hang in batch looks the same as slow work.
- Read the output; do not just check the exit code. A test run that loaded
  zero tests also "passes".
- Report honestly what was verified and what was not, e.g. "tested on Emacs
  30.1 only".
