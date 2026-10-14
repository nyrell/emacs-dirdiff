# Use what Emacs already has

Reimplementing standard functionality is the most common criticism of
LLM-written Emacs Lisp. Emacs has a large standard library, and much of it
is in no model's short-term memory. Search before you write.

## How to find out

| Question | Command |
|---|---|
| Which functions exist for strings, lists, files…? | `elisp-agent builtins GROUP` (in Emacs: `M-x shortdoc`) |
| Does this function exist? How is it called? | `elisp-agent describe NAME` |
| What does it really return? | `elisp-agent eval '(NAME ...)'` |
| Anything with "trim" in its name? | `elisp-agent eval '(apropos-internal "trim" (quote fboundp))'` |
| Which library defines a feature? | `elisp-agent eval '(locate-library "seq")'` |

Rule of thumb: if a helper takes less than three lines and sounds generic
("join paths", "trim a string", "unique elements"), it almost certainly
exists.

## Instead of writing it yourself

| Task | Use |
|---|---|
| Join directory and file name | `file-name-concat`, `expand-file-name` |
| Parts of a file name | `file-name-directory`, `file-name-nondirectory`, `file-name-base`, `file-name-extension`, `file-name-sans-extension`, `file-relative-name` |
| Show a file name to users | `abbreviate-file-name` |
| Find a parent directory with a marker file | `locate-dominating-file` |
| Project root | `project-current` + `project-root` |
| List a directory (recursively) | `directory-files`, `directory-files-and-attributes`, `directory-files-recursively` |
| Temporary file or directory | `make-temp-file` (with DIR-FLAG for a directory) |
| Trim, prefix, suffix | `string-trim`, `string-prefix-p`, `string-suffix-p`, `string-remove-prefix`, `string-remove-suffix` |
| Search or replace in a string | `string-search`, `string-replace`, `replace-regexp-in-string` |
| Split and join | `split-string`, `string-join`, `mapconcat`, `string-lines` |
| Pad or cut to a width | `string-pad`, `truncate-string-to-width`, `string-width` (display width, not `length`) |
| Empty / blank string | `string-empty-p`, `string-blank-p` |
| Unique elements, filter, reduce | `delete-dups`, `seq-uniq`, `seq-filter`, `seq-remove`, `seq-reduce`, `cl-remove-if` |
| Alist lookup | `alist-get`, `assoc-default` |
| Bind if non-nil | `when-let*`, `if-let*`, `and-let*` |
| Destructure | `pcase-let`, `pcase-dolist`, `seq-let` |
| Cache a computed value in a place | `with-memoization` |
| Toggle a boolean place | `(cl-callf not PLACE)` |
| Table of rows with columns | `tabulated-list-mode`, `vtable` |
| Clickable text | `insert-text-button`, `buttonize` |
| Ask yes/no, choose from a list | `y-or-n-p`, `yes-or-no-p`, `completing-read`, `read-answer`, `read-multiple-choice` |
| Read a file or directory name | `read-file-name`, `read-directory-name` |
| Run a program and get its output | `process-lines`, `call-process`, `process-file` |
| Quote a shell argument | `shell-quote-argument` |
| JSON | `json-parse-string`, `json-serialize` |
| Dates and times | `format-time-string`, `time-equal-p`, `time-less-p`, `date-to-time` |
| Thing at point | `thing-at-point`, `bounds-of-thing-at-point` |
| Text properties in a region | `text-property-search-forward`, `text-property-any`, `next-single-property-change` |
| Show a buffer | `display-buffer`, `pop-to-buffer` with action alists |
| Read-only buffer with `q` and `g` | `define-derived-mode … special-mode` + `revert-buffer-function` |
| Undo a buffer display | `quit-window` |
| Progress for long loops | `make-progress-reporter`, `progress-reporter-update` |
| Run later or repeatedly | `run-at-time`, `run-with-idle-timer` |
| Notify the user | `message`, `display-warning` |
| Menus of commands | `transient-define-prefix` (built in since Emacs 28), `easy-menu-define` |
| Diff two files | `ediff-files`, `diff-no-select` |

## Examples from this repository

- `dirdiff--join` was a two-line function equal to `file-name-concat`; removed.
- The column layout uses `truncate-string-to-width`, which pads and cuts by
  *display* width, so wide characters stay aligned; `substring` and `length`
  count characters and would not.
- The comparison opens its frame with `pop-to-buffer` and a
  `display-buffer-pop-up-frame` action instead of `make-frame`, so `q`
  (`quit-window`) deletes the frame without any bookkeeping.
- Running git uses `process-file` with an argument list, so file names with
  spaces or quotes need no quoting, and remote directories work.
