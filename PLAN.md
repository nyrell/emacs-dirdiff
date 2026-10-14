# dirdiff — plan

A Meld-like directory comparison tool for Emacs. File-vs-file diffs are
delegated to `ediff-files`; this package adds what Emacs lacks: a
side-by-side, synchronized, expandable directory tree comparison, usable for
plain directories and for git revisions.

## Goals

1. `M-x dirdiff`: pick two paths.
   - Two files → `ediff-files`.
   - Two directories → directory comparison view.
2. Directory view
   - Left tree / right tree, row-for-row aligned at all times.
   - Expanding/collapsing a directory affects both sides identically.
   - Scrolling and point movement are synchronized.
   - Each entry is classified and colored:
     - identical
     - changed (files differ / directory contains differences)
     - only on the left (missing on the right)
     - only on the right (missing on the left)
     - type conflict (file on one side, directory on the other)
   - The absent side shows a greyed placeholder so the rows stay aligned.
   - `RET` on a file pair → `ediff-files`; on a one-sided file → open it.
   - Navigation: next/previous difference, expand all / collapse all,
     filter (hide identical), refresh, quit.
3. Git integration
   - Compare two commits (or a commit vs. the working tree) of a repository.
   - Implementation: materialize only what's needed. List trees with
     `git ls-tree -r` / `git diff --raw` (gives status without touching file
     contents) and extract blobs with `git show REV:path` into temp files
     only when a file pair is opened in ediff.
   - This means the comparison engine must be backend-agnostic
     (filesystem backend, git backend).

## Architecture

```
dirdiff.el               options, faces, comparison engine (sources are
                         generic: `dirdiff-dir-source`), view mode,
                         commands, menus, `dirdiff`, `dirdiff-difftool`
dirdiff-git.el           git source (`dirdiff-git-source`), git commands,
                         magit / vc integration
bin/dirdiff-difftool     wrapper for `git difftool --dir-diff`
test/dirdiff-test.el     ERT tests
```

### Comparison engine

- Node: `name relpath left-type right-type status children`.
- File equality: size check first, then content (`cmp -s` when available,
  elisp fallback). Options: ignore whitespace? follow symlinks?
- Directory status is derived from children (changed if any descendant is
  not identical).
- Ignore list (defaults: `.git`, plus optional `.gitignore` handling).
- Large trees: compute lazily per directory, or compute asynchronously with
  progress; status of an unexpanded directory requires a full walk, so the
  first version walks everything eagerly, with a cache, and we optimize later.

### View

The view is a pure function of (comparison tree, set of expanded paths), which
makes sync trivial: both sides are rendered from the same list of visible
rows. Which Emacs mechanism renders those rows is the open question for
step 1 (prototypes, since removed).

## Steps

1. ✅ Widget prototypes → chose B2 (one buffer, two columns, active side).
2. ✅ Comparison engine (filesystem) + ERT tests.
3. ✅ Directory view: rendering, expand/collapse, sides, faces, ediff,
   navigation, copy/delete, menus (transient, menu bar, tool bar).
4. ✅ Git backend: revision vs revision / working tree; magit, vc and
   `M-x` entry points; `bin/dirdiff-difftool`.
5. Polish: asynchronous comparison for very large trees, docstrings for
   checkdoc, more columns (size/date), marking several entries for
   copy/delete, 3-way?
6. Packaging: package-lint, MELPA recipe.

## Decisions (2026-10-13)

- Emacs 29.1+; built-in libraries only (no magit-section dependency).
  magit integration is optional (loaded only when magit is present).
- Package name: `dirdiff` (repo: emacs-dirdiff).
- View: one buffer, two columns, with an *active side* (demo B2).
  TAB switches side; RET toggles a directory / ediffs a file pair.
  Actions (copy to other side, delete, open) apply to the active side.
- Comparison: full file contents. Optional "ignore whitespace".
  Ignore list (default `.git`, `.hg`, `.svn`, `CVS`, `_darcs`), toggleable.
  `.gitignore` is NOT consulted.
- Editing actions like meld: copy left→right / right→left (files and whole
  directories), delete, with confirmation; refresh after ediff/edits.
- Git: commit vs commit, commit vs working tree, working tree vs HEAD.
  Entry points: magit diff transient (replacing the user's `D p`, `D h`,
  `D w` difftool suffixes), vc-log, `M-x` command reading two revisions,
  and `git difftool -d --tool=dirdiff` via a wrapper script.

## Git design

Two complementary routes:

1. **Native backend** (used from magit / vc / M-x): list both sides with
   `git ls-tree -r -z` (blob ids) or the working tree. Equal blob ids ⇒
   identical, without reading contents (fast even for huge repos); working
   tree files are hashed with `git hash-object` only when the size matches.
   Blobs are extracted with `git cat-file` into temp files on demand for
   ediff. Commit sides are read-only; the working-tree side is editable.
   Shows the whole tree (identical files can be hidden), unlike difftool.
2. **`git difftool -d`** compatibility: `bin/dirdiff-difftool LOCAL REMOTE`
   calls `emacsclient` to open the comparison, then blocks until the session
   is closed in Emacs (git deletes its temp dirs as soon as the tool exits),
   e.g. by waiting for a marker file that Emacs removes on quit.
   `git config difftool.dirdiff.cmd 'dirdiff-difftool "$LOCAL" "$REMOTE"'`.

- Binary files: compared by size + mtime by default, byte by byte as an
  option (`b`).
- Git comparisons hide identical entries initially (difftool look);
  toggle with `=`.
