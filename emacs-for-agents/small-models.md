# Small and local models

Small models fail at Emacs Lisp in predictable ways: parentheses that do not
balance, functions that do not exist, and long chains of "fixes" that are
never run. The cure is the same each time: **let Emacs check, not the
model**, and make every step small enough that the check pinpoints the
mistake.

Commands are run from the project root. Copy them exactly, with the full
path `emacs-for-agents/tools/elisp-agent`.

## The loop

```
1. Pick ONE function to write or change.
2. Look up every function you are unsure of:
     emacs-for-agents/tools/elisp-agent describe NAME
3. Write or replace the WHOLE top-level form.
4. Check it (structure, then warnings):
     emacs-for-agents/tools/elisp-agent -L . check FILE
5. Try it (does it do the right thing?):
     emacs-for-agents/tools/elisp-agent -L . --require mypkg eval '(mypkg-f 1)'
     emacs-for-agents/tools/elisp-agent -L . test test/mypkg-test.el -s NAME
6. Only then: the next function.
```

Never make several changes before checking. If two edits are pending and the
check fails, the model cannot tell which edit broke it.

## Parentheses

- **Do not count parentheses by eye**, and do not reason about them in
  long chains of thought. Run `check`. It says, in words, which form is
  missing parens and where the next form starts, and its hint names the
  line where your indentation and your parens disagree.
- **Indent carefully; it is how the tool finds your paren mistakes.**
  Models get indentation right more often than parentheses. Write each
  line at the depth you mean, and the hint will point at the missing or
  extra `)`.
- **Replace whole top-level forms.** Get the line range from
  `emacs-for-agents/tools/elisp-agent forms FILE`, write the complete new
  `defun`, and replace the lines. Inserting or deleting single `)`
  characters is where most structure errors come from.
- **Keep forms short.** A function of 10–20 lines is easy to get right; one
  of 80 lines is not. Split into helpers.
- **Write the closing parens at the end of the last line** of a form,
  `(message "done"))))`, never on lines of their own.
- **Escape parens in character literals**: `?\(`, `?\)`, `?\;`, `?\"`.
  Unescaped ones are valid Lisp but break the paren check and indentation.
- **Once `check` passes**, `emacs-for-agents/tools/elisp-agent indent --fix FILE`
  normalizes the layout. It refuses files with broken parens.

## Invented functions and wrong arguments

- `describe` every function you have not seen in this codebase or in the
  output of `describe` already. It shows how to call it, says which
  `require` it needs, and suggests real names for invented ones
  (`string-length` → `length`).
- Add the `require` that `describe` names, e.g. `(require 'subr-x)`, at
  the top of the file.
- The byte-compiler catches the rest: "the function `foo` is not known to be
  defined", "called with 1 argument, but requires 2". **Treat every warning
  as an error.**
- When unsure what something returns, `eval` it instead of guessing:
  `emacs-for-agents/tools/elisp-agent eval '(split-string "a,,b" ",")'`.
- For a concept rather than one function (hooks, keymaps, text
  properties), read the manual section instead of guessing:
  `emacs-for-agents/tools/elisp-agent info --index elisp keymap`, then
  print the node it names. Read only the node you need; whole manuals do
  not fit in a small context.

## Testing

- Write the test before the code, with expected values that are obviously
  right (small inputs, written out in full).
- Run one test at a time while working:
  `emacs-for-agents/tools/elisp-agent -L . test test/mypkg-test.el -s NAME`.
- Read the failure: ERT prints the form and the actual value. Fix the code
  or, if the expected value was wrong, check it with `eval` before changing
  the test.
- Never change a test just to make it pass without saying why.

## Keep the code simple

Prefer constructs that are hard to get wrong:

| Prefer | Over |
|---|---|
| `let`, `let*`, `when`, `unless`, `cond`, `dolist` | `cl-loop` with many clauses |
| Simple `pcase` patterns (constants, strings) | Backquote patterns with nested commas |
| A named helper function | A long `lambda` inside a call |
| `if-let*` / `when-let*` | Nested `let` + `if` |
| Built-in functions ([use-builtins.md](use-builtins.md)) | Hand-written helpers |

## Stop rules

- **Two failed checks of the same form:** delete the form and write it
  again from scratch, from the top, in one go.
- **Two more failures after that:** stop. Describe the problem to the
  human instead of trying variations.
- Never claim the code works without the output of `check` and `test`.

## For the person running the model

- Give the model the `elisp-agent` commands as tools (shell, or tool
  definitions in gptel / ellama) and put the loop above in its instructions.
- Keep context small: give it one file, or one function and the functions
  it calls, plus [use-builtins.md](use-builtins.md).
- Let the model run code in a fresh batch Emacs, not in your session: an
  error there costs nothing.
