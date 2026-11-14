#!/bin/bash
set -Eeuo pipefail

on_err() {
  local rc=$?
  [ "$BASH_SUBSHELL" -eq 0 ] || return 0
  echo "[init-firewall] ERROR: firewall setup failed at line $1: $2 (exit $rc)." >&2
}
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

echo "[init-firewall] Setting up the firewall..."

if ! source /etc/claudeshell/lib-firewall.sh 2>/dev/null; then
  echo "[init-firewall] WARNING: /etc/claudeshell/lib-firewall.sh could not be loaded — enforcing the fixed Recommended allow-list."
  firewall_mode() { echo "recommended"; }
fi

command -v firewall_warn_unsupported >/dev/null 2>&1 && firewall_warn_unsupported || true

DOCKER_DNS_RULES="$(iptables-save 2>/dev/null | grep '127.0.0.11' || true)"

iptables -F
iptables -X
ipset destroy allowed-domains 2>/dev/null || true

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

if [ -n "$DOCKER_DNS_RULES" ]; then
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    iptables ${rule} 2>/dev/null || true
  done <<< "$DOCKER_DNS_RULES"
fi

DNS_SERVERS="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null)"
[ -n "$DNS_SERVERS" ] || DNS_SERVERS="127.0.0.11"

for ns in $DNS_SERVERS; do
  iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
done

ipset create allowed-domains hash:net

ANTHROPIC_RANGES=(
  "160.79.104.0/21"
)
ANTHROPIC_DOMAINS=(
  "api.anthropic.com"
  "console.anthropic.com"
  "platform.claude.com"
  "claude.ai"
  "statsig.anthropic.com"
  "statsig.com"
  "api.statsig.com"
)

RECOMMENDED_DOMAINS=(
  "registry.npmjs.org"
  "npmjs.org"
  "www.npmjs.org"
  "github.com"
  "api.github.com"
  "codeload.github.com"
  "raw.githubusercontent.com"
  "objects.githubusercontent.com"
  "gitlab.com"
  "registry.gitlab.com"
  "assets.gitlab-static.net"
  "pypi.org"
  "files.pythonhosted.org"
  "registry-1.docker.io"
  "auth.docker.io"
  "index.docker.io"
  "production.cloudflare.docker.com"
  "static.rust-lang.org"
  "crates.io"
  "static.crates.io"
  "index.crates.io"
)

for cidr in "${ANTHROPIC_RANGES[@]}"; do
  ipset add allowed-domains "$cidr" 2>/dev/null || true
done

ACTIVE_DOMAINS=("${ANTHROPIC_DOMAINS[@]}")
GITHUB_ACTIVE=0

if [ "$(firewall_mode)" = "recommended" ]; then
  ACTIVE_DOMAINS+=("${RECOMMENDED_DOMAINS[@]}")
  GITHUB_ACTIVE=1
fi

# Running total of GitHub /meta CIDRs actually added to the set (global; read by
# the Done line). Kept at top level so the here-string loop in
# enrich_github_ranges can update it in the current shell.
GITHUB_CIDRS_ADDED=0

# dig every active domain (incl. api.github.com) and add its A records to the
# ipset. Unchanged behaviour: an unresolvable domain logs a WARNING on stdout
# and is skipped (tolerated). No enforcing command here.
resolve_domains_into_set() {
  for entry in "${ACTIVE_DOMAINS[@]}"; do
    ips="$(dig +short "$entry" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
    if [ -z "$ips" ]; then
      echo "[init-firewall] WARNING: could not resolve $entry, skipping"
      continue
    fi
    while IFS= read -r ip; do
      ipset add allowed-domains "$ip" 2>/dev/null || true
    done <<< "$ips"
  done
}

# Fetch api.github.com/meta and add IPv4 CIDRs ONLY from the top-level keys
# git/api/web/packages — never actions/hooks/dependabot/importer/copilot/pages.
# BEST-EFFORT: always invoked as `enrich_github_ranges || true`, so a failed
# fetch / non-200 / rate-limit / no-wanted-CIDR body logs a WARNING and returns
# without aborting the container. The parser is jq-free and python3-free: awk
# (mawk) walks the whole body by brace/bracket depth, so it works on pretty and
# minified JSON alike, and awk exits 0 on no match (unlike grep -oE), so the
# pipeline never trips pipefail.
enrich_github_ranges() {
  [ "$GITHUB_ACTIVE" = "1" ] || return 0
  local meta cidrs cidr count=0
  meta="$(curl -s --max-time 5 https://api.github.com/meta || true)"
  cidrs="$(printf '%s\n' "$meta" | awk '
    BEGIN { want["git"]=1; want["api"]=1; want["web"]=1; want["packages"]=1 }
    # MINOR-1 / BF-P2-AC6: bound a candidate CIDR before it is emitted. Reject a
    # bad octet (>255), a bad prefix (not 0-32), and an implausibly broad prefix
    # (< 8, i.e. 0.0.0.0/0 and anything /1../7). Real /meta git/api/web/packages
    # ranges are /20..32, so a /8 floor cannot drop a legitimate GitHub range but
    # still kills a forged/MITM catch-all. mawk/POSIX-safe (split + numeric test).
    function cidr_ok(s,    parts, ip, k, p) {
      if (split(s, parts, "/") != 2) return 0
      p = parts[2]
      if (p !~ /^[0-9]+$/) return 0
      p = p + 0
      if (p < 8 || p > 32) return 0
      if (split(parts[1], ip, ".") != 4) return 0
      for (k = 1; k <= 4; k++) {
        if (ip[k] !~ /^[0-9]+$/) return 0
        if (ip[k] + 0 > 255) return 0
      }
      return 1
    }
    { body = body $0 "\n" }
    END {
      n = length(body); i = 1; depth = 0; curkey = ""; wanted = 0
      while (i <= n) {
        c = substr(body, i, 1)
        if (c == "\"") {
          j = i + 1; str = ""
          while (j <= n) {
            cj = substr(body, j, 1)
            if (cj == "\\") { str = str substr(body, j, 2); j += 2; continue }
            if (cj == "\"") break
            str = str cj; j++
          }
          k = j + 1
          while (k <= n && substr(body, k, 1) ~ /[ \t\r\n]/) k++
          if (substr(body, k, 1) == ":" && depth == 1) {
            curkey = str; wanted = (curkey in want)
          } else if (wanted && str ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) {
            if (cidr_ok(str)) print str   # silently skip out-of-bound / catch-all CIDRs
          }
          i = j + 1; continue
        }
        if (c == "{" || c == "[") { depth++; i++; continue }
        if (c == "}" || c == "]") { depth--; if (depth <= 1) { curkey=""; wanted=0 } i++; continue }
        i++
      }
    }
  ')"
  if [ -z "$cidrs" ]; then
    echo "[init-firewall] WARNING: no usable GitHub ranges from api.github.com/meta (fetch failed, rate-limited, or none under git/api/web/packages); keeping the named GitHub domains, will retry in 300s." >&2
    return 0
  fi
  while IFS= read -r cidr; do
    [ -n "$cidr" ] || continue
    ipset add allowed-domains "$cidr" 2>/dev/null || true
    count=$((count + 1))
  done <<< "$cidrs"
  GITHUB_CIDRS_ADDED=$((GITHUB_CIDRS_ADDED + count))
}

# Combined entry point for the 300 s background loop only.
refresh_allowed_domains() { resolve_domains_into_set; enrich_github_ranges || true; }

# Item 7 (Option A): resolve the named domains (incl. api.github.com) into the
# set, THEN make enforcement live (set-match ACCEPT + REJECT), and only THEN
# fetch /meta — so api.github.com is both in the set and covered by a live rule
# when the first foreground fetch runs. ipset membership is evaluated per packet,
# so CIDRs added after the rule take effect immediately.
resolve_domains_into_set

iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
iptables -A INPUT -j REJECT --reject-with icmp-admin-prohibited

enrich_github_ranges || true

github_note=""
if [ "$GITHUB_ACTIVE" = "1" ]; then
  if [ "$GITHUB_CIDRS_ADDED" -gt 0 ]; then
    github_note=" + ${GITHUB_CIDRS_ADDED} GitHub range(s) from api.github.com/meta"
  else
    github_note=" (GitHub /meta ranges not yet added; retrying in the background)"
  fi
fi

echo "[init-firewall] Done. Egress restricted to an allow-list of ${#ACTIVE_DOMAINS[@]} domain(s)/CIDR(s)${github_note}."

(
  while true; do
    sleep 300
    refresh_allowed_domains >/dev/null 2>&1 || true
  done
) &
disown
