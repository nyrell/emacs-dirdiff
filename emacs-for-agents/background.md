# Background

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
into Emacs or GNU ELPA ([emacs-devel, March 2026][5]). MELPA has no such
rule; its reviewers expect `package-lint` and `checkdoc` to be clean.

## Related work

Other people's notes and tools for the same problem; worth reading, and
the source of several ideas here:

- [xenodium/emacs-skills](https://github.com/xenodium/emacs-skills):
  Claude Code skills that drive a live Emacs through `emacsclient`
  (open, select, highlight, describe).
- [agent-emacs](https://clawhub.ai/pitze/skills/agent-emacs) (OpenClaw):
  a persistent Emacs daemon as the agent's workspace (buffers as state,
  TRAMP, Magit). It is about using Emacs, not writing Elisp; as a
  caution, it calls `s.el` and `dash.el` built-in, which they are not.
- [ollama-buddy's skills](https://github.com/captainflasmr/ollama-buddy/tree/main/.agents/skills):
  `elisp-dev` (debugging, Edebug, error messages) and `elisp-review` (a
  review checklist: hooks and advice removed, `user-error`, autoloads).
- [parenmedic](https://github.com/shcv/parenmedic): repairs parentheses
  from the indentation, also as an MCP server; the idea behind
  `check`'s hint.
- [Parinfer](https://shaunlebron.github.io/parinfer/): parens inferred from
  indentation, for editors.
- [The Emacs Lisp Style Guide](https://github.com/bbatsov/emacs-lisp-style-guide):
  community style beyond the manual's conventions.
- [relint](https://elpa.gnu.org/packages/relint.html): finds regexp
  mistakes; used by `check --regexp`.

## Sources

- Emacs Lisp manual, *Tips and Conventions*:
  [Coding Conventions](https://www.gnu.org/software/emacs/manual/html_node/elisp/Coding-Conventions.html),
  Key Binding Conventions, Programming Tips, Documentation Tips. Also in
  Emacs: `C-h i m elisp`, or `emacs-for-agents/tools/elisp-agent info elisp "Coding Conventions"`.
- [package-lint](https://github.com/purcell/package-lint), used by MELPA;
  [elisp-check](https://github.com/leotaku/elisp-check), the same checks as a
  GitHub Action.

[1]: https://operationnull.com/posts/local-llms-as-the-glue-for-complex-emacs-functions.html
[2]: https://cdn.jsdelivr.net/gh/bimawa/emacsclient-mcp@main/README.md
[3]: https://mirrorservice.org/sites/melpa.org/packages/emcp-readme.txt
[4]: https://pypi.org/project/elate/
[5]: https://lists.gnu.org/archive/html/emacs-devel/2026-03/msg00425.html
