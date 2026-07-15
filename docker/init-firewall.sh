#!/bin/bash
set -euo pipefail

echo "[init-firewall] Setting up the firewall..."

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

ANTHROPIC_STATIC_RANGES=(
  "160.79.104.0/21"
)

for cidr in "${ANTHROPIC_STATIC_RANGES[@]}"; do
  ipset add allowed-domains "$cidr" 2>/dev/null || true
done

ALLOWED_DOMAINS=(
  "api.anthropic.com"
  "console.anthropic.com"
  "platform.claude.com"
  "claude.ai"
  "statsig.anthropic.com"
  "statsig.com"
  "api.statsig.com"
  "registry.npmjs.org"
  "npmjs.org"
  "www.npmjs.org"
  "github.com"
  "api.github.com"
  "codeload.github.com"
  "raw.githubusercontent.com"
)

refresh_allowed_domains() {
  for domain in "${ALLOWED_DOMAINS[@]}"; do
    ips="$(dig +short "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
    if [ -z "$ips" ]; then
      echo "[init-firewall] WARNING: could not resolve $domain, skipping"
      continue
    fi
    while IFS= read -r ip; do
      ipset add allowed-domains "$ip" 2>/dev/null || true
    done <<< "$ips"
  done

  local github_meta
  github_meta="$(curl -s --max-time 5 https://api.github.com/meta || true)"
  if [ -n "$github_meta" ]; then
    echo "$github_meta" | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+"' | tr -d '"' | while read -r cidr; do
      ipset add allowed-domains "$cidr" 2>/dev/null || true
    done
  fi
}

refresh_allowed_domains

iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
iptables -A INPUT -j REJECT --reject-with icmp-admin-prohibited

echo "[init-firewall] Done. Egress restricted to an allow-list of ${#ALLOWED_DOMAINS[@]} domains + GitHub's ranges."

(
  while true; do
    sleep 300
    refresh_allowed_domains >/dev/null 2>&1 || true
  done
) &
disown
