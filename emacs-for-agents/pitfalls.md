# Pitfalls

Each of these cost real debugging time while writing dirdiff and its tools.

| Symptom | Cause | Fix |
|---|---|---|
| A `let` of another library's variable has no effect, or "Defining as dynamic an already lexical var" | The library was not loaded, so the variable was not yet special and the binding was lexical | `require` the library at the top of the file before binding its variables |
| A `cl-letf` mock is ignored | The function was autoloaded; the first call loaded the library, which replaced the mock | `require` the library before mocking |
| A search loop never ends | `syntax-ppss` (and other parsing functions) move point | Wrap such calls in `save-excursion`; check with `eval` what moves point |
| A `-r` option never reaches your script | Emacs removes some single-letter options itself (`-r` is reverse video) | Use long option names (`--require`) for your own scripts |
| A command works when called but not from keys | `post-command-hook`, keymaps and interactive specs only run in the command loop | Test with `execute-kbd-macro`, or call the hook in the test |
| A user's hook stops running after you add yours | Some hooks are run with only their buffer-local value (e.g. `ediff-after-quit-hook-internal`) | Include `(default-value 'HOOK)` in the local value |
| Columns misaligned with CJK or emoji | `length` counts characters, not display width | `string-width`, `truncate-string-to-width`, or text properties instead of character arithmetic |
| Header line misaligned with text | Line numbers take columns in the text area but not the header | `header-line-indent-mode` and `header-line-indent` (Emacs 29) |
| `face` text properties vanish | `font-lock-mode` is on and owns the `face` property | Use `font-lock-face`, or a mode without font-lock |
| Overwriting a file follows a symlink to somewhere else | `copy-file` and `write-region` write through symlinks | Delete the link first if you mean to replace it |
| `kill` or `pkill -f PATTERN` kills your own shell | The pattern also matches the shell's command line | Match the program name exactly, list processes before killing |
| `checkdoc-file` in batch prints warnings but returns success | In batch it reports through `display-warning` | Capture `display-warning` (after `(require 'warnings)`) or use `elisp-agent check --doc` |
| checkdoc: "Name emacs should appear capitalized as Emacs" for a shell command in a comment | checkdoc reads comments as prose | Quote commands like code: `` `emacs --batch ...' `` |
| `(ert-run-tests-batch-and-exit)` "passes" | No tests were loaded | Check the `Ran N tests` line |
| Elisp manual missing (`info` says not installed) | Debian ships it separately | Install `emacs-common-non-dfsg`, or read it online |
