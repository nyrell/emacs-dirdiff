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

### Keys in the dirdiff buffer

One side is *active* (highlighted). Visiting, copying and deleting act on
it.

| Key | Action |
|---|---|
| `TAB`, click | switch active side |
| `RET`, double-click | ediff the file pair (a file on one side only is compared with an empty file) / expand or collapse the directory |
| `n`, `p` | next / previous difference (expands directories as needed) |
| `^` | parent directory |
| `+`, `-`, `*` | expand all / collapse all / expand directories with differences |
| `=` | hide or show identical entries |
| `w` | ignore whitespace on/off (also used by ediff) |
| `b` | compare binary files byte by byte, or by size and time only |
| `g` | compare again |
| `>`, `<` | copy the entry to the right / left side (directories are replaced) |
| `d` | delete the entry on the active side (to the trash if `delete-by-moving-to-trash`) |
| `v` | visit the file on the active side in this window |
| `o` | visit the file on the active side in another window |
| `?` | menu with all commands |
| `q` | quit |

There is also a *Dirdiff* menu in the menu bar.

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

Suffixes already on these keys, such as `git difftool` ones, are
replaced.

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

[`examples/git-difftool.gitconfig`](examples/git-difftool.gitconfig) has
the same settings for `~/.gitconfig`, plus a `git dd` alias.

If an Emacs server is running (`M-x server-start`), the comparison opens
in a new frame there and the script waits until you quit it. Otherwise it starts a new
Emacs that exits when you quit the comparison. Set `DIRDIFF_EMACSCLIENT` or
`DIRDIFF_EMACS` to use other commands.

git hands the tool temporary copies, so the left side is read-only. When the
right side is your working tree, git fills it with links to your files: copying
a file onto one of those, or saving it in ediff, changes your working tree.
Adding or deleting files is refused there, because git would not pass the change
on; use `M-x dirdiff-git` for that.

## Command line

Like meld, from a shell:

```sh
emacs -L /path/to/emacs-dirdiff -l dirdiff -f dirdiff-command-line LEFT RIGHT
```

LEFT and RIGHT are two directories or two files. A new Emacs starts and
exits when you quit the comparison. Ready-made launchers:
[`examples/dirdiff`](examples/dirdiff) (shell; link it into your `PATH`)
and [`examples/dirdiff.bat`](examples/dirdiff.bat) (Windows).

## Customization

`M-x customize-group RET dirdiff`. Among others:

- `dirdiff-ignored-names` (`.git`, `.hg`, … by default; set to nil to include them)
- `dirdiff-ignore-whitespace`
- `dirdiff-binary-comparison`
- `dirdiff-hide-identical`
- `dirdiff-initial-expansion` — `changed` (default), `all` or `none`
- `dirdiff-new-frame` — `magit` (default: new frame when started from
  magit), `t` (always) or `nil` (never); `dirdiff-frame-parameters`
- faces `dirdiff-same`, `dirdiff-changed`, `dirdiff-new`, `dirdiff-absent`,
  `dirdiff-conflict`, `dirdiff-active-cell`

## Development

The checks use the `elisp-agent` tool from the emacs-for-agents
repository (notes on writing Emacs Lisp with coding agents), cloned next
to this one:

```sh
T=../emacs-for-agents/tools/elisp-agent
$T -L . check --doc dirdiff.el dirdiff-git.el   # parens, zero warnings, checkdoc
$T indent dirdiff.el dirdiff-git.el             # standard indentation
$T -L . test test/dirdiff-test.el               # ERT tests
```
