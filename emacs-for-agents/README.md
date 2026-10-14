# Emacs Lisp for coding agents

Practical notes for AI agents (and the people running them) that write Emacs
Lisp. Start here; each topic has its own file with the details.

## The rules that matter most

1. **Check after every edit.** Run `tools/elisp-agent check FILE` after every
   change. It reports missing or extra parentheses in plain words, then
   byte-compiles. Fix structure first, then compiler warnings, then anything
   else. Never leave a warning behind. → [tools.md](tools.md)
2. **Never guess a function.** Before using a function you have not just seen
   in the code, run `tools/elisp-agent describe NAME`. Invented functions
   (`string-length`) and wrong arguments are the most common LLM mistake.
3. **Look for a built-in first.** Before writing a helper, run
   `tools/elisp-agent builtins GROUP` (string, list, file-name, …). Emacs
   probably has it. → [use-builtins.md](use-builtins.md)
4. **Edit whole top-level forms.** Replace an entire `defun` rather than
   patching a few parentheses in the middle. `tools/elisp-agent forms FILE`
   gives the line range of each form.
5. **Test first, in batch.** Write an ERT test that fails, then make it pass.
   A test that never failed proves nothing. → [testing.md](testing.md)
6. **Follow the conventions.** `lexical-binding`, a package prefix,
   `prefix--private`, `provide`, docstrings, no side effects on load.
   → [best-practices.md](best-practices.md)
7. **Verify in steps.** Batch checks first, then a clean `emacs -Q`, then a
   real Emacs, without disturbing the user's own session.
   → [verification.md](verification.md)
8. **Small models: smaller steps.** One form per edit, a check after each, and
   a hard limit on retries. → [small-models.md](small-models.md)

## Files

| File | What it covers |
|---|---|
| [tools.md](tools.md) | `elisp-agent`: structure check, compile, describe, built-ins, eval, tests |
| [best-practices.md](best-practices.md) | Conventions: files, naming, loading, variables, modes, buffers, processes |
| [use-builtins.md](use-builtins.md) | What not to reinvent, and how to find what exists |
| [testing.md](testing.md) | ERT tests: layout, fixtures, mocking, testing commands and buffers |
| [verification.md](verification.md) | The verification ladder, from parens to screenshots of a live Emacs |
| [small-models.md](small-models.md) | Workflow for small local LLMs: parentheses, invented functions, loops |
| [pitfalls.md](pitfalls.md) | Traps that cost real debugging time, each with the fix |
| [templates.md](templates.md) | Skeletons for a package file, a major mode and a test file |

## Quick start

```sh
T=emacs-for-agents/tools/elisp-agent
$T check mypkg.el                 # parens, then byte-compile; exit 1 on problems
$T describe string-trim seq-reduce  # does it exist, and how is it called?
$T builtins string                # built-in string functions
$T -L . --require mypkg eval '(mypkg-parse "a,b")'
$T -L . test test/mypkg-test.el   # run ERT
```

## Use it in a project

This README is the entry point; no other instruction file is needed. Copy the
folder into the project (or point to it) and tell the agent:

> Read emacs-for-agents/README.md and follow it.

Then the agent should run the tool from the project root, with `-L .` so it
finds the project's own files. Work is done only when `check` and `test` pass,
and the agent shows their output.

## Why this exists

LLM-written Emacs Lisp is criticized for invented functions, reimplemented
built-ins, unbalanced parentheses and code that was never run. In experiments
with a local model, the model invented `string-length`, called `seq-reduce`
without its required initial value, and kept trying alternatives without
verifying them ([operationnull.com][1]). What helped was giving the model a way
to evaluate code in a clean, sandboxed `emacs -Q --batch` and to look up
docstrings. Other people let agents evaluate code in a live Emacs through an
MCP server ([emacsclient-mcp][2], [emcp][3], [elate][4]). This folder
collects that experience, plus the conventions from the Elisp manual, into
short notes and one small tool.

Note on policy: the GNU project currently does not accept LLM-generated code
into Emacs or GNU ELPA ([emacs-devel, March 2026][5]; [RMS on ELPA][6]).
MELPA has no such rule, but it requires `package-lint` and `checkdoc` to pass.

## Sources

- Emacs Lisp manual, *Tips and Conventions*:
  [Coding Conventions](https://www.gnu.org/software/emacs/manual/html_node/elisp/Coding-Conventions.html),
  Key Binding Conventions, Programming Tips, Documentation Tips. Also in Emacs
  (`C-h i m elisp`); on Debian, install `emacs-common-non-dfsg` for it.
- [package-lint](https://github.com/purcell/package-lint), required for MELPA;
  [elisp-check](https://github.com/leotaku/elisp-check), the same checks as a
  GitHub Action.

[1]: https://operationnull.com/posts/local-llms-as-the-glue-for-complex-emacs-functions.html
[2]: https://cdn.jsdelivr.net/gh/bimawa/emacsclient-mcp@main/README.md
[3]: https://mirrorservice.org/sites/melpa.org/packages/emcp-readme.txt
[4]: https://pypi.org/project/elate/
[5]: https://lists.gnu.org/archive/html/emacs-devel/2026-03/msg00425.html
[6]: https://freenode.net/article/rms-gnu-elpa-must-reject-llm-generated-packages
