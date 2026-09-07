#!/usr/bin/env bash
# Verify that every embedded image in tracked Markdown resolves on disk.
#
# Renaming a screenshot without updating the pages that embed it is otherwise
# invisible until the doc renders on GitHub, where it shows as a broken-image
# placeholder. This checks image references only: prose in these docs contains
# Swift selectors like (withTimeInterval:repeating:) that a general link parser
# misreads, and a check that cries wolf is a check people switch off.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

missing=$(
    while IFS= read -r doc; do
        dir=$(dirname "$doc")
        {
            # Markdown ![alt](path) and HTML <img src="path">.
            # grep exits 1 on a doc with no images, which is not an error here.
            grep -oE '!\[[^]]*\]\([^)]+\)' "$doc" | sed -E 's/^!\[[^]]*\]\(//; s/\)$//' || true
            grep -oE '<img[^>]+src="[^"]+"' "$doc" | sed -E 's/.*src="//; s/"$//' || true
        } | while IFS= read -r target; do
            target=${target%% *}   # drop a title: ![alt](path "title")
            # The leading "(" is load-bearing: CI runs on macOS, whose bash 3.2
            # matches parens to close $( ) without understanding case patterns,
            # so a bare `pattern)` in here is a syntax error.
            case "$target" in
                ('' | [Hh][Tt][Tt][Pp]://* | [Hh][Tt][Tt][Pp][Ss]://* | [Dd][Aa][Tt][Aa]:* | //*) continue ;;
            esac
            [ -e "$dir/$target" ] || echo "  $doc -> $target"
        done
    done < <(git ls-files '*.md')
)

if [ -n "$missing" ]; then
    echo "Markdown references images that do not exist:" >&2
    echo "$missing" >&2
    exit 1
fi

echo "All Markdown image references resolve."
