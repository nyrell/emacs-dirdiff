# elisp-agent

One script for the checks agents need most. Run it from the project root
as `emacs-for-agents/tools/elisp-agent` (written `$T` below, after
`T=emacs-for-agents/tools/elisp-agent`). It never touches a running Emacs
or the user's configuration. Output is one finding per line,
`FILE:LINE: message`; the exit status is 0 when all is well and 1
otherwise, so an agent can branch on it.

```
$T [OPTIONS] check [--doc] [--regexp] [--allow-warnings] FILE...
$T [OPTIONS] forms FILE
$T [OPTIONS] indent [--fix] FILE...
$T [OPTIONS] describe SYMBOL...
$T [OPTIONS] builtins [GROUP]
$T [OPTIONS] info [MANUAL [NODE]]
$T [OPTIONS] info --index MANUAL TOPIC
$T [OPTIONS] info --search MANUAL REGEXP
$T [OPTIONS] eval EXPRESSION...
$T [OPTIONS] test FILE... [-s SELECTOR]
```

**Options** go before the command: `-L DIR` (add to `load-path`; use
`-L .` for the project), `-l FILE` (load), `--require FEATURE`,
`--packages` (activate installed packages: from `ELISP_AGENT_PACKAGE_DIR`
if set, otherwise the user's own package directory, which is only read).
Set `EMACS` to use another Emacs binary.

**Clean Emacs.** Compiling, `describe`, `eval`, `test` and `builtins` run
in a fresh `emacs --batch -Q` with only these options, so a forgotten
`require` shows up as an error here and not later on someone else's
machine.

## check

1. **Structure.** Finds missing and extra parentheses and says where, in words:

   ```
   f.el:1: missing 1 closing paren(s) in the form starting at line 1: (defun a ... (line 7 starts a new top-level form inside it) Hint: line 3 is indented 4, but the parens put it at 8, so a ) is probably missing at the end of the code before line 3.
   g.el:3: extra closing paren; an earlier form was closed too early, so the indented form at line 3 ended up at top level: (bar Hint: line 3 is indented 2, but the parens put it at 0, so there is probably a ) too many before line 3.
   h.el:1: missing closing paren(s): this form is not closed before the end of the file: (defun a Hint: the indentation agrees with the parens, so the ) is probably missing at the end of line 5.
   ```

   The **hint comes from the indentation**: models indent by intention
   more reliably than they count parentheses (the idea behind
   [parenmedic][pm] and [Parinfer][pi]), so the first line whose written
   indentation disagrees with the parens is usually just after the mistake.
   The hint is only as good as the indentation, so keep it right.

   Parentheses in strings and comments are understood, and so are escaped
   character literals (`?\(`). Unescaped ones (`?(`, `?)`, `?;`, `?"`) are
   valid Lisp but confuse Emacs's paren scanner and indentation, so `check`
   reports them by line and asks for the escaped form.
2. **Byte-compile** in a clean Emacs (only if the structure is fine). Shows
   the compiler's warnings: unknown functions (often a missing `require`),
   wrong number of arguments, free variables, obsolete functions. **Warnings
   fail the check** unless `--allow-warnings`.
3. **checkdoc** with `--doc`: docstring and comment style (what MELPA
   reviewers check).
4. **relint** with `--regexp`: mistakes in regular expressions, such as
   Perl's `\s+` and `\d`, ranges like `[a-z_-.]`, and `^` where a file
   name needs `` \` ``. relint is a GNU ELPA package: if it is installed,
   add `--packages`; otherwise install it into a directory of your own
   (see [verification.md](verification.md#4-linters-without-touching-the-users-config)).

## forms

Lists each top-level form with its line range, e.g. `120-134: (defun mypkg-parse`.
Use it to replace a whole definition instead of patching parentheses.

## indent

Reports up to 10 lines that Emacs would indent differently. After a
misplaced paren, every following line in that form indents wrongly, so
**the first reported line is just after the mistake**.

`--fix` rewrites the files with Emacs's own indentation, keeping their line
endings and coding system. It refuses files whose parentheses are broken,
since re-indenting them would hide where the mistake is. (It loads the
file's `require`d libraries and evaluates its `defmacro`s first, so macro
indentation is right.)

## describe

```
$ $T describe string-trim string-length seq-reduce hash-table-keys
string-trim: function (string-trim STRING &optional TRIM-LEFT TRIM-RIGHT)
  Trim STRING of leading and trailing strings matching TRIM-LEFT and TRIM-RIGHT.
  defined in /usr/share/emacs/30.1/lisp/subr.elc
  first in NEWS: Emacs 24: *** 'string-trim'
string-length: NOT DEFINED  Similar: length
seq-reduce: function (seq-reduce FUNCTION SEQUENCE INITIAL-VALUE)
  Reduce the function FUNCTION across SEQUENCE, starting with INITIAL-VALUE.
  defined in /usr/share/emacs/30.1/lisp/emacs-lisp/seq.elc
hash-table-keys: NOT DEFINED in a clean Emacs; add (require 'subr-x)
hash-table-keys: function (hash-table-keys HASH-TABLE)
  Return a list of keys in HASH-TABLE.
  ...
```

For each symbol, as a clean Emacs sees it:
- the kind and how to call it;
- the first docstring line and the defining file;
- obsolescence and the replacement;
- the first NEWS heading that mentions it, which usually says when it
  appeared;
- for a variable, its value, shortened.

If the symbol is not defined, `describe` tries the common libraries and
tells you which `require` provides it. Otherwise it suggests similar names,
and recognizes names from popular packages that are not part of Emacs
(`s-trim` → `string-trim`). The exit status is 1 if any symbol is not
defined. Read the full docstring with
`$T eval '(documentation (quote NAME))'`.

## builtins

Without an argument, lists the topic groups from Emacs's `shortdoc`
(`string`, `list`, `alist`, `sequence`, `hash-table`, `file-name`, `file`,
`buffer`, `regexp`, `keymaps`, …). With a group, it prints every function
in it with its one-line summary, and marks those that need a `require`.
Check here before writing a helper.

## info

Reads the Info manuals (the Elisp reference manual is `elisp`, the user
manual is `emacs`) as plain text. Use `describe` for one function; use the
manual for concepts, conventions and how functions work together.

```
$ $T info                                    # installed manuals
$ $T info --index elisp add-hook             # where is it explained?
add-hook: (elisp) Setting Hooks, line N
$ $T info elisp "Setting Hooks"              # print that node
$ $T info "(elisp) Coding Conventions"       # cross-reference form
$ $T info --search elisp "buffer-local hook" # full text, up to 50 hits
```

Start with `--index`; it finds functions, variables and concepts. Use
`--search` when the index has nothing. A node's menu (`* Name::`) and
cross references (`*Note Name::`, `*note (emacs)Name::`) name other nodes;
read them with another `info` call. Nodes can be long, so pipe through
`head` or `sed -n` when you only need the start. If a manual or node is
missing, `info` says which, and for a missing manual prints the node's
address on gnu.org.

## eval

Evaluates each expression in a clean Emacs and prints its value, or
`ERROR: …` and goes on with the next one. Use it to check what a function
really returns instead of predicting it:

```
$ $T eval '(split-string "a,,b" ",")' '(car 5)' '(file-name-concat "" "x")'
("a" "" "b")
ERROR: Wrong type argument: listp, 5
"x"
```

Load your code with options before `eval`: `$T -L . --require mypkg eval '(mypkg-f 1)'`.
For a backtrace, see [verification.md](verification.md#when-something-fails).

## test

Runs ERT on the test files in a clean Emacs; `-s REGEXP` runs only the tests
whose names match. Add `-L .` so the tests find the package. It fails if no
test ran, which usually means a wrong file or selector.

## Tests of the tool

```sh
$T -L emacs-for-agents/tools test emacs-for-agents/tools/elisp-agent-test.el
```

## Giving the tool to a model

For an agent with shell access, the commands above are enough. For a chat
model in Emacs (gptel, ellama) or a local model with function calling,
expose `check`, `describe`, `builtins` and `eval` as tools that run the
script and return its output, and tell the model to call `check` after every
edit and `describe` before using an unfamiliar function.

[pm]: https://github.com/shcv/parenmedic
[pi]: https://shaunlebron.github.io/parinfer/
