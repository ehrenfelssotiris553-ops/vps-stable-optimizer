#!/usr/bin/env bash
# CI only. Makes a throwaway GitHub-hosted runner look more like a fresh VPS
# before the real run (layer 2):
# - Docker and its firewall rules go out of the way. The tool rightly refuses
#   to take over a firewall that already has rules.
# - An SSH server runs, because the firewall step needs real SSH ports.
# - Only the distribution's own package sources stay, as on a fresh VPS. The
#   image adds Microsoft, PPAs and others; one of them being down would fail
#   the tool's strict index update for a reason that has nothing to do with it.
# - expect is installed to answer the questions.
set -Eeuo pipefail
sudo mkdir -p /etc/apt/sources.list.d.ci-off
for f in /etc/apt/sources.list.d/*; do
  [[ -e "$f" ]] || continue
  case "${f##*/}" in ubuntu.sources) continue ;; esac
  sudo mv -- "$f" /etc/apt/sources.list.d.ci-off/
done
sudo systemctl stop docker.socket docker.service containerd.service 2>/dev/null || true
for tool in iptables ip6tables; do
  command -v "$tool" >/dev/null || continue
  for table in filter nat mangle raw; do
    sudo "$tool" -t "$table" -F 2>/dev/null || true
    sudo "$tool" -t "$table" -X 2>/dev/null || true
  done
  for chain in INPUT FORWARD OUTPUT; do sudo "$tool" -P "$chain" ACCEPT 2>/dev/null || true; done
done
if command -v nft >/dev/null; then sudo nft flush ruleset || true; fi
sudo systemctl disable --now nftables.service firewalld.service 2>/dev/null || true
sudo apt-get update -q
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends expect openssh-server
sudo systemctl enable --now ssh.service 2>/dev/null || sudo systemctl enable --now ssh.socket
printf 'Runner: %s, %s MiB RAM, swap: %s\n' "$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')" \
  "$(awk '/^MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo)" "$(swapon --noheadings --show=NAME | tr '\n' ' ')"
