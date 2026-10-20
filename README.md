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
for a file on one side and a directory on the other. The name of an
entry that is missing on one side is shown struck through on that side.

## Installation

Not on MELPA yet. Clone the repository and add to your init file:

```elisp
(add-to-list 'load-path "/path/to/emacs-dirdiff")
(require 'dirdiff)
(require 'dirdiff-git)
```

Or load [`examples/dirdiff-init.el`](examples/dirdiff-init.el), which sets
up everything below (the magit and vc keys, and `C-c =` in Dired) in one
line:

```elisp
(load "/path/to/emacs-dirdiff/examples/dirdiff-init.el")
```

## Usage

| Command | Compares |
|---|---|
| `M-x dirdiff` | two files (with ediff) or two directories; in Dired, the two marked entries |
| `M-x dirdiff-dired` | the two directories marked in the visible Dired windows |
| `M-x dirdiff-git` | git revisions, with `git difftool -d` syntax: `A..B`, `A...B`, `C^!` (a commit with its parent), `A` (with the working tree), or empty (`HEAD` with the working tree) |

When both directories are shown in Dired windows, side by side for
example, the comparison takes the place of both, and `q` restores the
windows as they were (`dirdiff-replace-dired-windows`).

### Keys in the dirdiff buffer

One side is *active*: its cell on the current row is highlighted and
marked `▶`, and so is its label in the header line. Visiting, copying and
deleting act on it.

| Key | Action |
|---|---|
| `TAB`, click | switch active side |
| `RET`, double-click | ediff the file pair (a file on one side only is compared with an empty file) / expand or collapse the directory |
| `n`, `p` | next / previous difference (expands directories as needed) |
| `^` | parent directory |
| `+`, `-`, `*` | expand all / collapse all / expand directories with differences |
| `=` | hide or show identical entries |
| `s` | ignore whitespace on/off (also used by ediff) |
| `e` | ignore line endings (CRLF vs LF) on/off (also used by ediff) |
| `x` | ignore the executable bit on/off |
| `B` | compare binary files byte by byte, or trust the same size and time |
| `g`, `!` | compare again |
| `>`, `<` (also `M-<right>`, `M-<left>`, or `a`, `b` as in ediff) | copy the entry to the right / left side (for directories, what differs; see below) |
| `d` | delete the entry on the active side (to the trash if `delete-by-moving-to-trash`) |
| `v` | visit the file on the active side in this window |
| `o` | visit the file on the active side in another window |
| `w` | copy the entry's name, like Dired: `C-u w` relative to the compared directories, `C-0 w` the full name (`REV:PATH` for a git revision) |
| `?` | menu with all commands |
| `q` | quit |

There is also a *Dirdiff* menu in the menu bar.

Copying a directory onto a directory changes only what differs: entries
that compare as identical are left alone, and so are entries that are
not compared at all (`dirdiff-ignored-names`, such as `.git`), so a
replaced or deleted directory stays if it still holds such entries.

### Comparing

Text files are compared by content (optionally ignoring whitespace, like
`diff -w`). By default, differences only in line endings (CRLF vs LF) or
in the executable bit are ignored; `e` and `x` turn that off, shown as
`[eol]` and `[x]` in the mode line.

When you quit an ediff started from dirdiff, it asks whether to save the
files you changed, then compares them again
(`dirdiff-save-after-ediff`: `ask`, `t` or `nil`).

Binary files (with a NUL byte in the first 8000 bytes) of the same size
and modification time are by default taken to be identical without
reading them; others of the same size are compared byte by byte. Press
`B` or set `dirdiff-binary-comparison` to `full` to always compare them
byte by byte.

## Git

Revisions are listed with `git ls-tree`, and which files differ comes from
`git diff --raw`, so even large repositories are compared quickly. File
contents are extracted (read-only, to a temporary directory) only when a
file is opened. Revision sides are read-only: copy and delete only work on
the working tree. A file copied from a revision is written as
`git checkout` would write it (`.gitattributes` line endings, filters
such as git-lfs). Submodules are shown as single entries; their contents
are not compared, copied or deleted.

Git comparisons hide identical entries initially, so they look like
`git difftool -d`; press `=` to see the whole tree
(`dirdiff-hide-identical` applies to directory comparisons).

### Magit

```elisp
(with-eval-after-load 'magit
  (require 'dirdiff-git)
  (dirdiff-magit-setup))
```

This adds to magit's diff menu (`d`):

| Key | Action |
|---|---|
| `D p` | a range, like `git difftool -d RANGE`; at a commit it suggests `<commit>^..<commit>`, the commit with its previous one; commits selected in a log give `A..B`, with a prefix argument `A...B` |
| `D h` | a revision with `HEAD` (`git difftool -d REV..HEAD`) |
| `D w` | a revision with the working tree (`git difftool -d REV`) |

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

To make dirdiff the tool for `git difftool --dir-diff`:

```sh
git config --global difftool.dirdiff.cmd 'emacs -f dirdiff-difftool-command-line "$LOCAL" "$REMOTE"'
git config --global difftool.prompt false
git difftool -d --tool=dirdiff HEAD~3
```

[`examples/git-difftool.gitconfig`](examples/git-difftool.gitconfig) has
the same settings for `~/.gitconfig`, plus a `git dd` alias. Your Emacs
init must load dirdiff, as described [above](#installation). A new Emacs
starts and exits when you quit the comparison.

git hands the tool temporary copies, so the left side is read-only. On the
right side, the files that are the same as in your working tree are links to
them, or, where git does not make links (`core.symlinks` false, as on
Windows), copies that git copies back when you quit. Copying onto those files,
or saving them in ediff, changes your working tree; other files there are
temporary and refused. Adding or deleting files is refused too, because git
would not pass the change on; use `M-x dirdiff-git` for that.

## Command line

Like meld, from a shell:

```sh
emacs -f dirdiff-command-line LEFT RIGHT
```

LEFT and RIGHT are two directories or two files. A new Emacs starts and
exits when you quit the comparison. Your Emacs init must load dirdiff, as
described [above](#installation). Ready-made launchers:
[`examples/dirdiff.sh`](examples/dirdiff.sh) (put it on your `PATH`) and
[`examples/dirdiff.bat`](examples/dirdiff.bat) (Windows).

## Customization

`M-x customize-group RET dirdiff`. Among others:

- `dirdiff-ignored-names` (`.git`, `.hg`, … by default; set to nil to include them)
- `dirdiff-ignore-whitespace`, `dirdiff-ignore-line-endings`,
  `dirdiff-ignore-file-modes`
- `dirdiff-save-after-ediff` — `ask` (default), `t` or `nil`
- `dirdiff-binary-comparison`
- `dirdiff-hide-identical`
- `dirdiff-initial-expansion` — `changed` (default), `all` or `none`
- `dirdiff-replace-dired-windows` — `t` (default) or `nil`
- `dirdiff-new-frame` — `magit` (default: new frame when started from
  magit), `t` (always) or `nil` (never); `dirdiff-frame-parameters`
- faces `dirdiff-same`, `dirdiff-changed`, `dirdiff-new`, `dirdiff-absent`,
  `dirdiff-conflict`, `dirdiff-active-cell`, `dirdiff-active-marker`

## Development

```sh
emacs --batch -Q -L . --eval '(setq byte-compile-error-on-warn t)' \
      -f batch-byte-compile dirdiff.el dirdiff-git.el     # zero warnings
emacs --batch -Q -L . -l test/dirdiff-test.el \
      -f ert-run-tests-batch-and-exit                     # ERT tests
```

The magit tests are skipped unless magit can be loaded; to use your
installed packages, add `-f package-initialize` after `-Q` (and set
`package-user-dir` first if yours is not the default).
