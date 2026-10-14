# dirdiff — compare directory trees side by side in Emacs

Dirdiff does for directories what `ediff-files` does for files, in the
spirit of [Meld](https://meldmerge.org/): both trees are shown side by side
in one buffer, row for row, and expanding a directory expands it on both
sides. Identical, changed, left-only and right-only entries are colored
differently. `RET` on a pair of files opens them in ediff.

It also compares **git revisions** (commit vs commit, commit vs working
tree) without checking anything out, and it can be used as the tool for
`git difftool --dir-diff`.

Requires Emacs 29.1 or later. No other dependencies; magit integration is
optional.

```
~/project-v1                            ~/project-v2
▾ docs/                              | ▾ docs/
  ▸ old/                             <   ▸ old/
    index.md                             index.md
▾ src/                               | ▾ src/
  ▸ net/                             |   ▸ net/
    feature.c                        >     feature.c
    legacy.c                         <     legacy.c
    main.c                           |     main.c
```

The middle column shows `|` changed, `<` left only, `>` right only and `!`
for a file on one side and a directory on the other.

## Installation

Not on MELPA yet. Clone the repository and add to your init file:

```elisp
(add-to-list 'load-path "/path/to/emacs-dirdiff")
(require 'dirdiff)
(require 'dirdiff-git)
```

## Usage

| Command | Compares |
|---|---|
| `M-x dirdiff` | two files (with ediff) or two directories; in Dired, the two marked entries |
| `M-x dirdiff-dired` | the two directories marked in the visible Dired windows |
| `M-x dirdiff-git` | git revisions, with `git difftool -d` syntax: `A..B`, `A...B`, or `A` (vs. working tree) |
| `M-x dirdiff-git-commit` | a commit with its parent |
| `M-x dirdiff-git-head` | a revision with `HEAD` |
| `M-x dirdiff-git-worktree` | a revision with the working tree |
| `M-x dirdiff-git-status` | `HEAD` with the working tree |

### Keys in the dirdiff buffer

One side is *active* (highlighted). Visiting, copying and deleting act on
it.

| Key | Action |
|---|---|
| `TAB`, `←`, `→` | switch active side |
| `RET`, double-click | ediff the file pair / expand or collapse the directory / visit a one-sided file |
| `SPC` | expand or collapse directory |
| `n`, `p` | next / previous difference (expands directories as needed) |
| `C-n`, `C-p`, `↑`, `↓` | next / previous row |
| `^` | parent directory |
| `+`, `-`, `*` | expand all / collapse all / expand directories with differences |
| `=` | hide or show identical entries |
| `w` | ignore whitespace on/off (also used by ediff) |
| `b` | compare binary files byte by byte, or by size and time only |
| `I` | leave out `.git`, `.hg`, `.svn`, … on/off |
| `g` | compare again |
| `>`, `<` | copy the entry to the right / left side (directories are replaced) |
| `c` | copy from the active side to the other side |
| `d` | delete the entry on the active side (to the trash if `delete-by-moving-to-trash`) |
| `o`, `f` | visit the file on the active side (other window / this window) |
| `?` | menu with all commands |
| `q` | quit |

There is also a *Dirdiff* menu in the menu bar and a tool bar.

### Comparing

Text files are compared by content (optionally ignoring whitespace, like
`diff -w`). Binary files (with a NUL byte in the first 8000 bytes) are by
default compared by size and modification time only; press `b` or set
`dirdiff-binary-comparison` to `full` to compare them byte by byte.
`.gitignore` files are not consulted.

## Git

Revisions are listed with `git ls-tree`, and which files differ comes from
`git diff --raw`, so even large repositories are compared quickly. File
contents are extracted (read-only, to a temporary directory) only when a
file is opened. Revision sides are read-only: copy and delete only work on
the working tree.

Git comparisons hide identical entries initially, so they look like
`git difftool -d`; press `=` to see the whole tree
(`dirdiff-git-hide-identical`).

### Magit

```elisp
(with-eval-after-load 'magit
  (require 'dirdiff-git)
  (dirdiff-magit-setup))
```

This adds to magit's diff menu (`d`):

| Key | Action |
|---|---|
| `D p` | range or commit (`dirdiff-git`; suggests `<commit>^..<commit>` at a commit) |
| `D h` | revision against `HEAD` |
| `D w` | revision against the working tree |

Comparisons started from magit open in a new (maximized) frame, so
magit's windows are left alone; `q` deletes the frame again. See
`dirdiff-new-frame` and `dirdiff-frame-parameters`.

See [`examples/dirdiff-magit-config.el`](examples/dirdiff-magit-config.el)
for a complete example, including how to pick your own keys.

### vc

```elisp
(with-eval-after-load 'log-view
  (require 'dirdiff-git)
  (dirdiff-vc-setup))
```

Binds `D` in `vc-print-log` buffers: compare the revision at point with its
parent, or the oldest and newest revisions in the region.

### git difftool

`bin/dirdiff-difftool` makes dirdiff the tool for `git difftool --dir-diff`:

```sh
git config --global difftool.dirdiff.cmd '/path/to/emacs-dirdiff/bin/dirdiff-difftool "$LOCAL" "$REMOTE"'
git config --global difftool.prompt false
git difftool -d --tool=dirdiff HEAD~3
```

If an Emacs server is running (`M-x server-start`), the comparison opens
in a new frame there and the script waits until you quit it. Otherwise it starts a new
Emacs that exits when you quit the comparison. Set `DIRDIFF_EMACSCLIENT` or
`DIRDIFF_EMACS` to use other commands.

Editing the right side in `git difftool -d` edits your working tree, as with
other tools.

## Customization

`M-x customize-group RET dirdiff`. Among others:

- `dirdiff-ignored-names`, `dirdiff-use-ignored-names`
- `dirdiff-ignore-whitespace`
- `dirdiff-binary-comparison`
- `dirdiff-hide-identical`, `dirdiff-git-hide-identical`
- `dirdiff-initial-expansion` — `changed` (default), `all` or `none`
- `dirdiff-new-frame` — `magit` (default: new frame when started from
  magit), `t` (always) or `nil` (never); `dirdiff-frame-parameters`
- faces `dirdiff-same`, `dirdiff-changed`, `dirdiff-new`, `dirdiff-absent`,
  `dirdiff-conflict`, `dirdiff-active-cell`

## Tests

```sh
emacs --batch -Q -L . -l test/dirdiff-test.el -f ert-run-tests-batch-and-exit
```
