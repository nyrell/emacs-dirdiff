#!/bin/sh
# dirdiff.sh -- compare two files or directories in Emacs, like meld.
#
#   dirdiff.sh LEFT RIGHT
#
# Your Emacs init must load dirdiff (see dirdiff-init.el).  Copy or
# link this script into a directory on your PATH.  A new Emacs starts
# and exits when the comparison is quit.

if [ $# -ne 2 ]; then
    echo "usage: dirdiff.sh LEFT RIGHT" >&2
    exit 2
fi

exec emacs -f dirdiff-command-line "$1" "$2"
