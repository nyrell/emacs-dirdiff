# tools/elisp-agent

One script for the checks agents need most. It runs a fresh `emacs --batch -Q`,
so nothing from the user's configuration interferes, and it never touches a
running Emacs. Output is one finding per line, `FILE:LINE: message`. The exit
status is 0 when all is well and 1 otherwise, so an agent can branch on it.

```
elisp-agent check [--doc] [--allow-warnings] FILE...
elisp-agent forms FILE
elisp-agent indent [--fix] FILE...
elisp-agent describe SYMBOL...
elisp-agent builtins [GROUP]
elisp-agent eval EXPRESSION...
elisp-agent test FILE... [-s SELECTOR]
```

Options for every command (give `-L` to `check` too, so it can compile files
that `require` your package): `-L DIR` (add to `load-path`), `-l FILE` (load),
`--require FEATURE`, `--packages` (activate installed packages, from
`ELISP_AGENT_PACKAGE_DIR` or the default `package-user-dir`). Set `EMACS` to
use another Emacs binary.

## check

1. **Structure.** Finds missing and extra parentheses and says where, in words:

   ```
   f.el:2: missing 1 closing paren(s) in the form starting at line 2: (defun my-a ... (line 7 starts a new top-level form inside it)
   f.el:4: extra closing paren; the form starting at line 2 has one ) too many: (defun my-a
   f.el:7: missing closing paren(s): this form is not closed before the end of the file: (defun my-b
   ```

   Parentheses inside strings, comments and `?\(` are understood.
2. **Byte-compile** (only if the structure is fine). Shows the compiler's
   warnings: unknown functions, wrong number of arguments, free variables,
   unused values. **Warnings fail the check** unless `--allow-warnings`.
3. **checkdoc** with `--doc`: docstring and comment style (what MELPA checks).

## forms

Lists each top-level form with its line range, e.g. `120-134: (defun mypkg-parse`.
Use it to replace a whole definition instead of patching parentheses.

## indent

Reports lines Emacs would indent differently. After a misplaced paren, every
following line in that form indents wrongly, so **the first reported line is
just after the mistake**. `--fix` rewrites the files with Emacs's own
indentation; do this only once `check` passes. (It loads the file's `require`d
libraries and evaluates its `defmacro`s first, so macro indentation is right.)

## describe

```
$ elisp-agent describe string-trim string-length seq-reduce
string-trim: function (string &optional trim-left trim-right)
  Trim STRING of leading and trailing strings matching TRIM-LEFT and TRIM-RIGHT.
  defined in /usr/share/emacs/30.1/lisp/subr.elc
string-length: NOT DEFINED (load or require its library first?)  Similar: length
seq-reduce: function (function sequence initial-value)
  Reduce the function FUNCTION across SEQUENCE, starting with INITIAL-VALUE.
```

Kind (function, macro, command, special form, variable), argument list, first
docstring line, file, and obsolescence. Functions from libraries that are not
preloaded need `--require LIB`. Read the full docstring with
`eval '(documentation (quote NAME))'`.

## builtins

Without an argument, lists the topic groups from Emacs's `shortdoc`: `string`,
`list`, `alist`, `sequence`, `hash-table`, `file-name`, `file`, `buffer`,
`text-properties`, `overlay`, `process`, `regexp`, `keymaps`, `number`,
`vector`, `symbol`, `comparison`. With a group, prints every function in it
with its one-line summary. Check here before writing a helper.

## eval

Evaluates each expression and prints the result with `prin1`, or `ERROR: …`.
Use it to check what a function really returns, instead of predicting it:

```
$ elisp-agent eval '(split-string "a,,b" ",")' '(file-name-concat "" "x")'
("a" "" "b")
"x"
```

## test

Loads the test files and runs ERT; `-s SELECTOR` runs matching tests only
(a regexp on the test name). Add `-L .` so the tests find the package.

## Tests of the tool

```sh
emacs --batch -Q -L emacs-for-agents/tools -l emacs-for-agents/tools/elisp-agent-test.el \
  -f ert-run-tests-batch-and-exit
```

## Giving the tool to a model

For an agent with shell access, the commands above are enough. For a chat
model in Emacs (gptel, ellama) or a local model with function calling,
expose `check`, `describe`, `builtins` and `eval` as tools that run the
script and return its output, and tell the model to call `check` after every
edit and `describe` before using an unfamiliar function.
