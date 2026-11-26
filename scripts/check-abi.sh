#!/usr/bin/env bash
# aur-forge check-abi — find built packages whose shared-library or Python
# dependencies no longer resolve against the CURRENT build chroot.
#
# Why: AUR builds are only triggered when the upstream AUR version changes.
# When Arch bumps a soname (libfoo.so.1 -> .2) or the Python minor version,
# every package we built against the old one is silently broken for clients
# who run `pacman -Syu`, until upstream happens to release again. This is the
# same job Arch's rebuild-detector (`checkrebuild`) does for installed
# packages, adapted to a repo of built artifacts (nothing is installed).
#
# usage: check-abi.sh [--root DIR] [--repo-dir DIR] [--name REPO_NAME] [PKG ...]
#   --root      refreshed devtools chroot root   (default /var/lib/archbuild/extra-x86_64/root)
#   --repo-dir  served repo                       (default /repo/<REPO_NAME>.x86_64)
#   PKG ...     only inspect these package names  (default: every package in the repo)
# stdout : one TAB-separated line per stale package:  <pkgname>\t<reason>
#            reason = missing=libA.so.1,libB.so.2   and/or   python=3.14->3.15
# stderr : diagnostics.   exit 0 even when stale packages are found.
#
# What it checks (and what it does not):
#   * DT_NEEDED sonames of every ELF file in the package must be provided by the
#     chroot (/usr/lib, /lib), by an official package (the sync dbs' %PROVIDES%,
#     e.g. libX11.so=6-64) or files db (usr/lib/libX11.so.6) — the build chroot
#     is minimal, so runtime deps such as libx11 are NOT installed there — by
#     the package itself (bundled libs), or by
#     another package in this repo.
#   * usr/lib/pythonX.Y/ payloads must match a python in the chroot.
#   * NOT checked: dlopen()ed libraries, perl/ruby/lua/node module ABIs, symbol
#     versions. These are rare for the packages we host; extend if one bites.
#
# Per-package scan results are cached under $ABI_STATE_DIR/needed/ keyed on the
# package file name+size (files are immutable), so after the first run a night
# costs one `find` over the chroot plus cheap set comparisons.
set -uo pipefail

ABI_STATE_DIR="${ABI_STATE_DIR:-/cache/abi}"
READELF="${READELF:-readelf}"

# scan_package FILE CACHEFILE — extract FILE and write its facts to CACHEFILE:
#   N <soname>   needed by some ELF in the package
#   O <libname>  shared object shipped by the package (anywhere: bundled libs)
#   S <libname>  shared object installed in the system loader path
#                (usr/lib, usr/lib32, lib — top level only), i.e. visible to
#                OTHER packages
#   P <X.Y>      python minor the payload was built for
scan_package() {
    local file="$1" cache="$2" tmp
    tmp="$(mktemp -d "${ABI_STATE_DIR}/scan.XXXXXX")" || return 1
    if ! tar --no-same-owner -xf "$file" -C "$tmp" 2>/dev/null; then
        rm -rf "$tmp"; return 1
    fi
    {
        find "$tmp" \( -type f -o -type l \) -name '*.so*' -printf 'O %f\n'
        find "$tmp/usr/lib" "$tmp/usr/lib32" "$tmp/lib" -maxdepth 1 \( -type f -o -type l \) -name '*.so*' -printf 'S %f\n' 2>/dev/null
        find "$tmp" -type f -size +0 \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) -print0 2>/dev/null \
            | xargs -0 -r "$READELF" -d 2>/dev/null \
            | sed -n 's/.*(NEEDED)[[:space:]]*Shared library: \[\(.*\)\].*/N \1/p'
        local d
        for d in "$tmp"/usr/lib/python3.*; do
            [[ -d "$d" ]] && printf 'P %s\n' "${d##*/python}"
        done
    } | sort -u > "${cache}.tmp"
    mv -f "${cache}.tmp" "$cache"
    rm -rf "$tmp"
}

# Newest file per package name in DIR, restricted to NAMES (all if empty).
latest_files() {
    local dir="$1"; shift
    local -a want=("$@")
    local -A best=() bestfile=()
    local f b name ver w ok
    for f in "$dir"/*.pkg.tar.zst; do
        [[ -e "$f" ]] || continue
        b="${f##*/}"
        [[ "$b" =~ ^(.+)-([^-]+-[^-]+)-([^-]+)\.pkg\.tar\.zst$ ]] || continue
        name="${BASH_REMATCH[1]}"; ver="${BASH_REMATCH[2]}"
        if [[ ${#want[@]} -gt 0 ]]; then
            ok=0; for w in "${want[@]}"; do [[ "$w" == "$name" ]] && ok=1; done
            (( ok )) || continue
        fi
        if [[ -z "${best[$name]:-}" ]] || _gt "$ver" "${best[$name]}"; then
            best[$name]="$ver"; bestfile[$name]="$f"
        fi
    done
    for name in "${!bestfile[@]}"; do printf '%s\t%s\n' "$name" "${bestfile[$name]}"; done | sort
}

_gt() {
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

main() {
    local root="/var/lib/archbuild/extra-x86_64/root" dir="" name="${REPO_NAME:-aur-forge}"
    local -a pkgs=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root)     root="$2"; shift 2 ;;
            --repo-dir) dir="$2"; shift 2 ;;
            --name)     name="$2"; shift 2 ;;
            -h|--help)  sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' ; exit 0 ;;
            -*)         echo "check-abi: unknown option $1" >&2; exit 2 ;;
            *)          pkgs+=("$1"); shift ;;
        esac
    done
    dir="${dir:-/repo/${name}.x86_64}"
    [[ -d "$dir" ]]  || { echo "[abi] repo dir $dir missing" >&2; exit 0; }
    [[ -d "$root/usr/lib" ]] || { echo "[abi] chroot root $root/usr/lib missing — skipping" >&2; exit 0; }
    mkdir -p "${ABI_STATE_DIR}/needed"

    # 1. Facts for every candidate package (cached).
    local -A cache_of=()
    local n f key cache
    while IFS=$'\t' read -r n f; do
        [[ -z "$n" ]] && continue
        key="$(basename "$f").$(stat -c %s "$f" 2>/dev/null)"
        cache="${ABI_STATE_DIR}/needed/${key}.facts"
        if [[ ! -s "$cache" ]]; then
            scan_package "$f" "$cache" || { echo "[abi] could not scan $f — skipped" >&2; continue; }
        fi
        cache_of[$n]="$cache"
    done < <(latest_files "$dir" "${pkgs[@]}")
    # Libraries a package installs into the system loader path also satisfy
    # OTHER packages' dependencies (e.g. libsodium-1.0.18 -> a package linking
    # libsodium.so.23). Use all repo packages for that, not just the requested
    # ones. Libs bundled in /opt/<app>/ do not count — nothing else can load them.
    local -A repo_libs=()
    while IFS=$'\t' read -r n f; do
        [[ -z "$n" ]] && continue
        key="$(basename "$f").$(stat -c %s "$f" 2>/dev/null)"
        cache="${ABI_STATE_DIR}/needed/${key}.facts"
        [[ -s "$cache" ]] || scan_package "$f" "$cache" || continue
        local l
        while read -r l; do repo_libs[$l]=1; done < <(sed -n 's/^S //p' "$cache")
    done < <(latest_files "$dir")

    # 2. What the chroot provides right now.
    local -A sys=()
    local l
    while IFS= read -r l; do sys[$l]=1; done < <(
        find "$root/usr/lib" "$root/usr/lib32" "$root/lib" "$root/lib64" \
             \( -type f -o -type l \) -name '*.so*' -printf '%f\n' 2>/dev/null | sort -u)
    # Sonames the official repos currently provide (autogenerated %PROVIDES%
    # like "libX11.so=6-64"). A package depending on libx11 will get it at
    # install time even though the minimal build chroot does not have it.
    local -A prov=() prov_name=()
    local db
    for db in "$root"/var/lib/pacman/sync/*.db; do
        [[ -f "$db" ]] || continue
        while IFS= read -r l; do
            prov[$l]=1; prov_name[${l%%=*}]=1
        done < <(tar -xOf "$db" --wildcards '*/desc' 2>/dev/null \
                 | awk '/^%PROVIDES%$/{p=1;next} /^%/{p=0} p&&/\.so/{print}')
    done
    # Many libraries (libX11, libdrm, libxcb, libgbm...) carry no soname
    # %PROVIDES%, so also read the files dbs (`pacman -Fy`, done by update.sh):
    # any usr/lib/*.so* shipped by an official package is obtainable.
    local -A offi=()
    for db in "$root"/var/lib/pacman/sync/*.files; do
        [[ -f "$db" ]] || continue
        while IFS= read -r l; do offi[$l]=1; done < <(
            tar -xOf "$db" --wildcards '*/files' 2>/dev/null \
            | awk -F/ 'NF==3 && $1=="usr" && $2=="lib" && $3 ~ /\.so/ {print $3}')
    done
    local -a root_py=()
    local d
    for d in "$root"/usr/lib/python3.*; do [[ -d "$d" ]] && root_py+=("${d##*/python}"); done

    # 3. Compare.
    local stale=0
    for n in $(printf '%s\n' "${!cache_of[@]}" | sort); do
        local -a miss=()
        local -A own=()
        local k v
        while read -r k v; do
            case "$k" in O) own[$v]=1 ;; esac
        done < "${cache_of[$n]}"
        while read -r k v; do
            [[ "$k" == "N" ]] || continue
            [[ "$v" =~ ^(linux-vdso|ld-linux|ld64|linux-gate) ]] && continue
            [[ -n "${sys[$v]:-}" || -n "${own[$v]:-}" || -n "${repo_libs[$v]:-}" ]] && continue
            [[ -n "${offi[$v]:-}" ]] && continue
            # official provides: libfoo.so.N <-> libfoo.so=N-64 ; plain libfoo.so <-> any libfoo.so=*
            if [[ "$v" =~ ^(.+\.so)\.(.+)$ ]]; then
                [[ -n "${prov[${BASH_REMATCH[1]}=${BASH_REMATCH[2]}-64]:-}" ]] && continue
            else
                [[ -n "${prov_name[$v]:-}" ]] && continue
            fi
            miss+=("$v")
        done < "${cache_of[$n]}"
        local reason=""
        [[ ${#miss[@]} -gt 0 ]] && reason="missing=$(IFS=,; echo "${miss[*]}")"
        if [[ ${#root_py[@]} -gt 0 ]]; then
            local pv have
            while read -r k pv; do
                [[ "$k" == "P" ]] || continue
                have=0; for p in "${root_py[@]}"; do [[ "$p" == "$pv" ]] && have=1; done
                (( have )) || reason="${reason:+$reason }python=${pv}->${root_py[*]}"
            done < "${cache_of[$n]}"
        fi
        if [[ -n "$reason" ]]; then
            printf '%s\t%s\n' "$n" "$reason"
            stale=$((stale+1))
        fi
    done
    echo "[abi] checked ${#cache_of[@]} package(s) against $root: ${stale} stale" >&2
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
