# tools/elisp-agent

One script for the checks agents need most. It runs a fresh `emacs --batch -Q`,
so nothing from the user's configuration interferes, and it never touches a
running Emacs. Output is one finding per line, `FILE:LINE: message`. The exit
status is 0 when all is well and 1 otherwise, so an agent can branch on it.

```
elisp-agent check [--doc] [--regexp] [--allow-warnings] FILE...
elisp-agent forms FILE
elisp-agent indent [--fix] FILE...
elisp-agent describe SYMBOL...
elisp-agent builtins [GROUP]
elisp-agent info [MANUAL [NODE]]
elisp-agent info --index MANUAL TOPIC
elisp-agent info --search MANUAL REGEXP
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

   Parentheses inside strings, comments and `?\(` are understood. Each
   error comes with a **hint from the indentation**: models indent by
   intention more reliably than they count parentheses (the idea behind
   [parenmedic][pm] and [Parinfer][pi]), so the first line whose written
   indentation disagrees with the parens is usually just after the mistake:

   ```
   f.el:1: missing 1 closing paren(s) in the form starting at line 1: (defun a ... (line 7 starts a new top-level form inside it) Hint: line 3 is indented 4, but the parens put it at 8, so a ) is probably missing at the end of the code before line 3.
   ```

   The hint is only as good as the indentation, so keep it right.
2. **Byte-compile** (only if the structure is fine). Shows the compiler's
   warnings: unknown functions, wrong number of arguments, free variables,
   unused values. **Warnings fail the check** unless `--allow-warnings`.
3. **checkdoc** with `--doc`: docstring and comment style (what MELPA checks).
4. **relint** with `--regexp`: mistakes in regular expressions, such as
   Perl's `\s+` and `\d`, ranges like `[a-z_-.]`, and `^` where a file
   name needs `` \` ``. relint is a GNU ELPA package; install it once
   (see [verification.md](verification.md#4-linters-without-touching-the-users-packages))
   and add `--packages`.

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

## info

Reads the Info manuals (the Elisp reference manual is `elisp`, the user
manual is `emacs`) as plain text. Use `describe` for one function; use the
manual for concepts, conventions and how functions work together.

```
$ elisp-agent info                                    # installed manuals
$ elisp-agent info --index elisp add-hook             # where is it explained?
add-hook: (elisp) Setting Hooks, line N
$ elisp-agent info elisp "Setting Hooks"              # print that node
$ elisp-agent info "(elisp) Coding Conventions"       # cross-reference form
$ elisp-agent info --search elisp "buffer-local hook" # full text, up to 50 hits
```

Start with `--index`; it finds functions, variables and concepts. Use
`--search` when the index has nothing. A node's menu (`* Name::`) and
cross references (`*Note Name::`, `*note (emacs)Name::`) name other nodes;
read them with another `info` call. Nodes can be long, so pipe through
`head` or `sed -n` when you only need the start.

If a manual is not installed, `info` says so, lists what is installed and
prints the node's address on gnu.org. On Debian and Ubuntu the Emacs
manuals are in the package `emacs-common-non-dfsg`.

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

[pm]: https://github.com/shcv/parenmedic
[pi]: https://shaunlebron.github.io/parinfer/
