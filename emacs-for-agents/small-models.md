# Small and local models

Small models fail at Emacs Lisp in predictable ways: parentheses that do not
balance, functions that do not exist, and long chains of "fixes" that are
never run. The cure is the same each time: **let Emacs check, not the
model**, and make every step small enough that the check pinpoints the
mistake.

## The loop

```
1. Pick ONE function to write or change.
2. describe every function you are unsure of      (elisp-agent describe)
3. write or replace the WHOLE top-level form
4. elisp-agent check FILE                        (structure, then warnings)
5. elisp-agent eval / test                        (does it do the right thing?)
6. only then: next function
```

Never make several changes before checking. If two edits are pending and the
check fails, the model cannot tell which edit broke it.

## Parentheses

- **Do not count parentheses by eye**, and do not reason about them in
  long chains of thought. Run `elisp-agent check`. It says, in words,
  which form is missing parens and where the next form starts.
- **Replace whole top-level forms.** Get the line range from
  `elisp-agent forms FILE`, write the complete new `defun`, and replace the
  lines. Inserting or deleting single `)` characters is where most
  structure errors come from.
- **Keep forms short.** A function of 10–20 lines is easy to get right; one
  of 80 lines is not. Split into helpers.
- **Write the closing parens at the end of the last line** of a form,
  `(message "done"))))`, never on lines of their own.
- **Use indentation as a second opinion.** `elisp-agent indent FILE` shows
  where Emacs would indent differently; the first such line is right after
  a misplaced paren. Once `check` passes, `elisp-agent indent --fix FILE`
  normalizes the layout.
- If a form keeps failing the structure check after two attempts,
  **delete it and write it again from scratch**, from the top, in one go.

## Invented functions and wrong arguments

- `describe` every function you have not seen in this codebase or in the
  output of `describe` already: `elisp-agent describe seq-reduce`. It shows
  the arguments and suggests real names for invented ones
  (`string-length` → `length`).
- Functions from libraries need the library: `--require seq`.
- The byte-compiler catches the rest: "the function `foo` is not known to be
  defined", "called with 1 argument, but requires 2". **Treat every warning
  as an error.**
- When unsure what something returns, `eval` it instead of guessing:
  `elisp-agent eval '(split-string "a,,b" ",")'`.

## Testing

- Write the test before the code, with expected values that are obviously
  right (small inputs, written out in full).
- Run one test at a time while working: `elisp-agent test FILE -s NAME`.
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
| Built-in functions (`use-builtins.md`) | Hand-written helpers |

## Stop rules

- Same error three times in a row: stop, rewrite the form from scratch, or
  ask the human. Do not keep trying variations.
- More than about five attempts at one function: the design is probably
  wrong; describe the problem to the human instead.
- Never claim the code works without the output of `check` and `test`.

## For the person running the model

- Give the model the `elisp-agent` commands as tools (shell, or tool
  definitions in gptel / ellama) and put the loop above in its instructions.
- Keep context small: give it one file, or one function and the functions
  it calls, plus [use-builtins.md](use-builtins.md).
- Let the model run code in a fresh batch Emacs, not in your session: an
  error there costs nothing.
