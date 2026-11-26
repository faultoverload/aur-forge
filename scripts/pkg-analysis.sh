#!/usr/bin/env bash
# aur-forge pkg-analysis.sh — static, NON-EXECUTING analysis helpers for the
# package page (cgi-bin/package.cgi). Sourced; no side effects at source time.
#
# Nothing here sources or runs a PKGBUILD: a quarantined PKGBUILD is, by
# definition, untrusted code. Everything is grep/awk/diff over the text.
#
# These are HEURISTICS to point a reviewer at the interesting lines, not a
# verdict. archcanary (the known-bad list) and the human read are the gate.

# pkgbuild_findings FILE — emit "line<TAB>severity<TAB>rule<TAB>text", sorted by line.
# severity: high | medium | info.  Commented-out lines are ignored.
pkgbuild_findings() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    local -a rules=(
        # severity|rule|extended regex (case-insensitive)
        'high|pipe-to-shell|(curl|wget|fetch)[^|#]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([[:space:]]|$)'
        'high|decodes-base64|base64[[:space:]]+(-d|--decode)|openssl[[:space:]]+enc[[:space:]]+-d'
        'high|eval|(^|[;&|[:space:]])eval[[:space:]]'
        'high|reverse-shell-ish|/dev/(tcp|udp)/|(nc|ncat|netcat)[[:space:]]+(-e|--exec)|bash[[:space:]]+-i[[:space:]]+>&'
        'high|setuid|chmod[[:space:]]+([0-9]*[24-7][0-9]{3}|[ugoa]*\+s)'
        'high|ld-preload|LD_PRELOAD|ld\.so\.preload'
        'high|persistence|crontab|/etc/cron|authorized_keys|ssh-keygen|/etc/rc\.local|systemctl[[:space:]]+(--user[[:space:]]+)?(enable|preset)'
        'high|account-or-sudo-change|useradd|usermod|chpasswd|visudo|/etc/sudoers|NOPASSWD'
        'high|installs-from-network-at-build|(npm|pnpm|yarn|bun)[[:space:]]+(install|add|i)[[:space:]]|pip3?[[:space:]]+install|gem[[:space:]]+install|go[[:space:]]+install|cargo[[:space:]]+install'
        'high|miner-or-known-bad-word|xmrig|minerd|cryptonight|stratum\+tcp|atomic-lockfile'
        'medium|checksum-skipped|(sha(1|224|256|384|512)|md5|b2|ck)sums[^=]*=\(.*SKIP'
        'medium|plain-http-source|(source|_url)[^=]*=.*\bhttp://'
        'medium|unpinned-git-source|git\+https?://[^"#[:space:])]*[\x27"[:space:])]|git\+https?://[^#[:space:]"]*$'
        'medium|url-shortener-or-paste|bit\.ly|tinyurl|pastebin|paste\.ee|hastebin|transfer\.sh|discord(app)?\.com/api/webhooks|ngrok'
        'medium|pgp-check-skipped|--skippgpcheck|--skipinteg|--skipchecksums'
        'medium|network-in-pkgver|pkgver\(\)[^}]*(curl|wget)'
        'medium|obfuscation-hex|(\\x[0-9a-fA-F]{2}){6,}'
        'medium|obfuscation-long-blob|[A-Za-z0-9+/=]{120,}'
        'info|runs-as-root-helpers|(^|[;&|[:space:]])sudo[[:space:]]'
        'info|writes-outside-pkgdir|(>|install[[:space:]]+-[A-Za-z]*D?m?[0-9]*[[:space:]].*)[[:space:]]/(etc|usr|opt|var)/[^$]'
    )
    local r sev name re
    for r in "${rules[@]}"; do
        sev="${r%%|*}"; r="${r#*|}"; name="${r%%|*}"; re="${r#*|}"
        grep -nEi -- "$re" "$f" 2>/dev/null \
          | grep -vE '^[0-9]+:[[:space:]]*#' \
          | { if [[ "$name" == obfuscation-* ]]; then grep -vE '^[0-9]+:[[:space:]]*(sha(1|224|256|384|512)|md5|b2|ck)sums' || true; else cat; fi; } \
          | awk -F: -v sev="$sev" -v name="$name" '{ line=$1; sub(/^[0-9]+:/,""); gsub(/\t/," "); print line "\t" sev "\t" name "\t" substr($0,1,200) }'
    done | sort -t$'\t' -k1,1n -k3,3
    # Very long lines are a classic obfuscation carrier.
    awk 'length($0) > 400 { printf "%d\tmedium\tvery-long-line\t(%d characters)\n", NR, length($0) }' "$f"
    return 0
}

# findings_summary FILE — "H high, M medium, I info" counts (stdout).
findings_summary() {
    pkgbuild_findings "$1" | awk -F'\t' '$2=="high"{h++} $2=="medium"{m++} $2=="info"{i++} END{printf "%d high, %d medium, %d info", h, m, i}'
}

# unified_diff OLD NEW [max_lines] — unified diff, capped (default 400 lines).
unified_diff() {
    local old="$1" new="$2" max="${3:-400}"
    [[ -f "$old" && -f "$new" ]] || return 0
    diff -u --label approved --label quarantined -- "$old" "$new" | head -n "$max" || true
}

# static_srcinfo DIR — "key<TAB>value" lines from .SRCINFO when present, else a
# grep of PKGBUILD for single-line scalar assignments. Never executes anything.
static_srcinfo() {
    local d="$1"
    if [[ -s "$d/.SRCINFO" ]]; then
        sed -n 's/^[[:space:]]*\([a-z_0-9]\+\) = \(.*\)$/\1\t\2/p' "$d/.SRCINFO" \
          | grep -E '^(pkgbase|pkgname|pkgver|pkgrel|epoch|pkgdesc|arch|url|license|depends|makedepends|checkdepends|optdepends|provides|conflicts|source|source_x86_64|install|validpgpkeys)'$'\t'
    elif [[ -f "$d/PKGBUILD" ]]; then
        grep -E '^(pkgname|pkgver|pkgrel|epoch|pkgdesc|arch|url|license|install)=' "$d/PKGBUILD" \
          | sed -E "s/^([a-z]+)=[\"'(]*([^\"')]*).*/\1\t\2/"
    fi
}

# sourced_urls FILE — URLs mentioned in the PKGBUILD (static), one per line, unique.
sourced_urls() {
    [[ -f "$1" ]] || return 0
    grep -oE "https?://[^\"' )]+" "$1" | sort -u
}
