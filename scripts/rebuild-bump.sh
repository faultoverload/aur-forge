#!/usr/bin/env bash
# aur-forge rebuild-bump — give a forced rebuild a version clients will install.
#
# A rebuild against newer system libraries (soname bump, python minor bump)
# leaves the AUR pkgver/pkgrel unchanged, so the new file would carry the SAME
# version as the one already in the repo and pacman clients would never see an
# update. Arch's convention is to bump pkgrel; since pkgrel belongs to the AUR
# maintainer we use a decimal rebuild suffix instead (1 -> 1.1 -> 1.2), which
# vercmp orders strictly between pkgrel 1 and 2, so a real upstream pkgrel
# bump (2) still supersedes our rebuild.
#
# Pure functions only — safe to source from build.sh and from tests.

# rb_ver_gt A B — true if A is a newer version than B.
rb_ver_gt() {
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

# next_rebuild_pkgrel REPO_VER EPOCH PKGVER PKGREL
#   REPO_VER : newest "[epoch:]pkgver-pkgrel" already in the repo ("" if none)
#   EPOCH    : epoch from the PKGBUILD ("" or 0 when unset)
#   stdout   : the pkgrel to build with
#   returns 1 if no strictly-newer version can be produced (e.g. upstream
#            pkgver went backwards) — the caller must then refuse to build.
next_rebuild_pkgrel() {
    local repo_ver="${1:-}" epoch="${2:-}" pkgver="$3" pkgrel="$4"
    local prefix=""
    [[ -n "$epoch" && "$epoch" != "0" ]] && prefix="${epoch}:"
    local src_ver="${prefix}${pkgver}-${pkgrel}"

    if [[ -z "$repo_ver" ]] || rb_ver_gt "$src_ver" "$repo_ver"; then
        printf '%s\n' "$pkgrel"      # genuinely newer (or first build): no bump
        return 0
    fi

    local repo_rel="${repo_ver##*-}" cand
    if [[ "$repo_rel" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        cand="${BASH_REMATCH[1]}.$(( BASH_REMATCH[2] + 1 ))"
    elif [[ "$repo_rel" =~ ^[0-9]+$ ]]; then
        cand="${repo_rel}.1"
    else
        return 1
    fi
    if rb_ver_gt "${prefix}${pkgver}-${cand}" "$repo_ver"; then
        printf '%s\n' "$cand"
        return 0
    fi
    return 1
}
