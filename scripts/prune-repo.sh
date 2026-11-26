#!/usr/bin/env bash
# aur-forge prune-repo — drop old package versions from the served repo.
#
# Keeps the newest KEEP_VERSIONS (default 2: current + one rollback) files per
# package name and ALWAYS keeps whatever version the repo db currently points
# at. Deleting a file never touches the db, because repo-add already replaced
# the older entries when the newer package was added.
#
# usage: prune-repo.sh [--keep N] [--dry-run] [--repo-dir DIR] [--name REPO_NAME]
# Prints one "prune <file>" line per removed (or, with --dry-run, removable)
# package; exits 0.
#
# Pure helpers (prune_candidates) are exposed so the test suite can exercise
# them without touching a real repo.
set -euo pipefail

# _pv_gt A B — true if version A is newer than B (vercmp, else sort -V).
_pv_gt() {
    if command -v vercmp >/dev/null 2>&1; then
        (( $(vercmp "$1" "$2") > 0 ))
    else
        # No vercmp (dev host): compare epochs numerically, then `sort -V`.
        local a="$1" b="$2" ea=0 eb=0
        [[ "$a" == *:* ]] && { ea="${a%%:*}"; a="${a#*:}"; }
        [[ "$b" == *:* ]] && { eb="${b%%:*}"; b="${b#*:}"; }
        if (( ea != eb )); then (( ea > eb )); return; fi
        [[ "$a" != "$b" && "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" == "$a" ]]
    fi
}

# prune_candidates KEEP PROTECTED_FILE < file-basenames
#   stdin : package file basenames (*.pkg.tar.zst), one per line
#   arg2  : file with "name-[epoch:]ver-rel" entries that must never be pruned
#   stdout: basenames to remove
prune_candidates() {
    local keep="$1" protected="${2:-/dev/null}"
    local -A vers=()       # name -> newline-joined "ver<TAB>file"
    local b name ver
    while IFS= read -r b; do
        [[ "$b" =~ ^(.+)-([^-]+-[^-]+)-([^-]+)\.pkg\.tar\.zst$ ]] || continue
        name="${BASH_REMATCH[1]}"; ver="${BASH_REMATCH[2]}"
        vers[$name]+="${ver}"$'\t'"${b}"$'\n'
    done
    local n
    for n in "${!vers[@]}"; do
        # insertion-sort the versions newest-first using _pv_gt
        local -a sorted=()
        local line v f placed i
        while IFS=$'\t' read -r v f; do
            [[ -z "$v" ]] && continue
            placed=0
            for i in "${!sorted[@]}"; do
                if _pv_gt "$v" "${sorted[$i]%%$'\t'*}"; then
                    sorted=("${sorted[@]:0:$i}" "${v}"$'\t'"${f}" "${sorted[@]:$i}")
                    placed=1; break
                fi
            done
            (( placed )) || sorted+=("${v}"$'\t'"${f}")
        done <<< "${vers[$n]}"
        local idx=0
        for line in "${sorted[@]}"; do
            v="${line%%$'\t'*}"; f="${line#*$'\t'}"
            idx=$((idx+1))
            (( idx <= keep )) && continue
            grep -qxF "${n}-${v}" "$protected" 2>/dev/null && continue
            printf '%s\n' "$f"
        done
    done
}

main() {
    local keep="${KEEP_VERSIONS:-2}" dry=0
    local name="${REPO_NAME:-aur-forge}" dir=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep)      keep="$2"; shift 2 ;;
            --dry-run|-n) dry=1; shift ;;
            --repo-dir)  dir="$2"; shift 2 ;;
            --name)      name="$2"; shift 2 ;;
            *) echo "usage: $0 [--keep N] [--dry-run] [--repo-dir DIR] [--name REPO_NAME]" >&2; exit 2 ;;
        esac
    done
    [[ "$keep" =~ ^[1-9][0-9]*$ ]] || { echo "[prune] --keep must be a positive integer (got '$keep')" >&2; exit 2; }
    dir="${dir:-/repo/${name}.x86_64}"
    [[ -d "$dir" ]] || { echo "[prune] repo dir $dir missing" >&2; exit 1; }

    local db="${dir}/${name}.db.tar.zst"
    # No db => we cannot tell which versions are live; refuse to delete anything.
    [[ -s "$db" ]] || { echo "[prune] no ${name}.db.tar.zst in $dir — nothing pruned" >&2; exit 0; }

    # global (not local): the EXIT trap runs after main() has returned
    PROTECTED_TMP="$(mktemp)"
    trap 'rm -f "${PROTECTED_TMP:-}"' EXIT
    local protected="$PROTECTED_TMP"
    tar -tf "$db" | awk -F/ 'NF==2 && $2=="" {print $1}' > "$protected"

    local removed=0 f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        printf 'prune %s\n' "$f"
        if (( ! dry )); then
            rm -f -- "${dir}/${f}" "${dir}/${f}.sig"
        fi
        removed=$((removed+1))
    done < <( (cd "$dir" && ls -1 -- *.pkg.tar.zst 2>/dev/null) | prune_candidates "$keep" "$protected" )
    echo "[prune] keep=${keep} ${removed} file(s) $([[ $dry -eq 1 ]] && echo 'would be ')removed from $dir" >&2
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
