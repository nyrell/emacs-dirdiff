# Testing with ERT

ERT is Emacs's built-in test framework. Tests run in batch, need no
packages, and give the agent a yes/no answer it can act on.

## Layout and running

```
mypkg.el
test/mypkg-test.el      ; (require 'ert) (require 'mypkg), ends with (provide 'mypkg-test)
```

```sh
emacs --batch -Q -L . -l test/mypkg-test.el -f ert-run-tests-batch-and-exit
emacs-for-agents/tools/elisp-agent -L . test test/mypkg-test.el -s 'parse'   # only matching tests
```

The last lines say `Ran N tests, N results as expected, 0 unexpected`, and the
exit status is non-zero when a test fails. A failing test prints the form
and the values it compared (`:form (equal 3 4) :value nil`).

## The basic shape

```elisp
(ert-deftest mypkg-test-parse-empty ()
  "An empty string has no fields."
  (should (equal (mypkg-parse "") nil)))
```

- `should`, `should-not`, `(should-error FORM :type 'user-error)`.
- Name tests `mypkg-test-WHAT`, so `-s` can select them.
- Compare whole values with `equal`, not piece by piece. One expected value
  says more than ten `should`s.
- **Get expected values from Emacs, not from your head**: run
  `elisp-agent eval` to see what a function returns, decide whether that is
  right, then paste it into the test.

## Test first, and see it fail

For a bug: write the test, run it, **see it fail for the right reason**, then
fix. For new code: a test of the intended behavior first. A test written
after the code often just repeats the code's mistakes. To prove a test
detects a bug, run it against the old version too (`git show HEAD:file.el`
into a temporary directory, then `-L` that directory).

## Fixtures: files and directories

```elisp
(defmacro mypkg-test--with-dir (&rest body)
  "Run BODY with `dir' bound to a new temporary directory."
  (declare (indent 0))
  `(let ((dir (make-temp-file "mypkg-test-" t)))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))
```

- Always `unwind-protect` the cleanup.
- Write files with `write-region` (bind `coding-system-for-write` to
  `no-conversion` for binary data).
- Git repositories in tests: `git init`, and set `GIT_AUTHOR_NAME`,
  `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME` and `GIT_COMMITTER_EMAIL` in
  `process-environment`, so tests do not depend on the user's git config.
- Set file times explicitly (`set-file-times`) when behavior depends on them.

## Mocking

`cl-letf` replaces a function for the duration of a form:

```elisp
(cl-letf (((symbol-function 'yes-or-no-p) (lambda (prompt) (push prompt prompts) nil))
          ((symbol-function 'ediff-files) (lambda (&rest _) (error "Should not run ediff"))))
  (mypkg-delete-thing))
```

- Use it for prompts (`y-or-n-p`, `yes-or-no-p`, `read-string`), for things
  that need a display (`ediff-files`, `make-frame`), and to capture `message`
  output. Record the arguments and assert on them: the exact prompt text is
  behavior too.
- **Load the function's library before mocking it.** If the function is
  autoloaded, the first call loads the library, which redefines the
  function and silently removes your mock. (`(require 'warnings)` before
  mocking `display-warning`, for example.)

## Testing commands and buffers

- Call commands as functions in the right buffer: `(with-current-buffer buf
  (mypkg-next-item))`. Interactive specs are not run; pass arguments.
- Assert on **what the user sees**: `(buffer-substring-no-properties
  (point-min) (point-max))`, normalized (collapse runs of spaces) if
  alignment is not the point. Check text properties with
  `get-text-property` where they carry meaning.
- **`post-command-hook` does not run** when a test calls a command. Call
  your hook function explicitly after the command, or use
  `execute-kbd-macro` with real keys (see [verification.md](verification.md)).
- Batch has one small frame and no real display: `window-width` is about
  80 columns, `display-graphic-p` is nil, and `make-frame` fails. Make
  window- and frame-dependent code testable, e.g. with an option that skips
  the new frame.
- Kill buffers the test created, in `unwind-protect`.

## What to cover

- The happy path, and each kind of input that changes the result (empty,
  missing on one side, wide characters, symlinks, binary files).
- Each bug you fix, with a test that failed before the fix.
- Error paths: `should-error` with the error type, so a `user-error` (user
  mistake) is not confused with a crash.
- Destructive commands: that they ask, that declining changes nothing, and
  that accepting does exactly what the prompt said.
