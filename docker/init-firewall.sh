#!/bin/bash
set -euo pipefail

echo "[init-firewall] Setting up the firewall..."

if ! source /etc/claude-shell/lib-firewall.sh 2>/dev/null; then
  echo "[init-firewall] WARNING: /etc/claude-shell/lib-firewall.sh could not be loaded — falling back to curated Recommended defaults in-process."
  firewall_mode() { echo "recommended"; }
  firewall_service_enabled() {
    case "$1" in
      npm|github|gitlab|pypi|dockerhub|rust) return 0 ;;
      *) return 1 ;;
    esac
  }
  firewall_custom_list() { :; }
fi

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

declare -A SERVICE_DOMAINS=(
  [npm]="registry.npmjs.org npmjs.org www.npmjs.org"
  [github]="github.com api.github.com codeload.github.com raw.githubusercontent.com objects.githubusercontent.com"
  [gitlab]="gitlab.com registry.gitlab.com assets.gitlab-static.net"
  [pypi]="pypi.org files.pythonhosted.org"
  [dockerhub]="registry-1.docker.io auth.docker.io index.docker.io production.cloudflare.docker.com"
  [huggingface]="huggingface.co cdn-lfs.huggingface.co cdn-lfs-us-1.huggingface.co"
  [microsoft]="api.nuget.org nuget.org marketplace.visualstudio.com vscode.blob.core.windows.net dotnet.microsoft.com download.visualstudio.microsoft.com"
  [apple]="developer.apple.com swift.org download.swift.org"
  [go]="proxy.golang.org sum.golang.org"
  [rust]="static.rust-lang.org crates.io static.crates.io index.crates.io"
)

for cidr in "${ANTHROPIC_RANGES[@]}"; do
  ipset add allowed-domains "$cidr" 2>/dev/null || true
done

ACTIVE_DOMAINS=("${ANTHROPIC_DOMAINS[@]}")
GITHUB_ACTIVE=0

if [ "$(firewall_mode)" = "recommended" ]; then
  for slug in "${!SERVICE_DOMAINS[@]}"; do
    if firewall_service_enabled "$slug"; then
      ACTIVE_DOMAINS+=(${SERVICE_DOMAINS[$slug]})
      [ "$slug" = "github" ] && GITHUB_ACTIVE=1
    fi
  done
  while IFS= read -r custom; do
    [ -n "$custom" ] && ACTIVE_DOMAINS+=("$custom")
  done < <(firewall_custom_list)
fi

refresh_allowed_domains() {
  for entry in "${ACTIVE_DOMAINS[@]}"; do
    case "$entry" in
      */*)
        ipset add allowed-domains "$entry" 2>/dev/null || true
        ;;
      *)
        ips="$(dig +short "$entry" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
        if [ -z "$ips" ]; then
          echo "[init-firewall] WARNING: could not resolve $entry, skipping"
          continue
        fi
        while IFS= read -r ip; do
          ipset add allowed-domains "$ip" 2>/dev/null || true
        done <<< "$ips"
        ;;
    esac
  done

  if [ "$GITHUB_ACTIVE" = "1" ]; then
    local github_meta
    github_meta="$(curl -s --max-time 5 https://api.github.com/meta || true)"
    if [ -n "$github_meta" ]; then
      echo "$github_meta" | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+"' | tr -d '"' | while read -r cidr; do
        ipset add allowed-domains "$cidr" 2>/dev/null || true
      done
    fi
  fi
}

refresh_allowed_domains

iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
iptables -A INPUT -j REJECT --reject-with icmp-admin-prohibited

echo "[init-firewall] Done. Egress restricted to an allow-list of ${#ACTIVE_DOMAINS[@]} domain(s)/CIDR(s)$( [ "$GITHUB_ACTIVE" = "1" ] && echo " + GitHub's ranges" )."

(
  while true; do
    sleep 300
    refresh_allowed_domains >/dev/null 2>&1 || true
  done
) &
disown
