#!/usr/bin/env bash
set -euo pipefail

banner() {
  echo
  echo "================================================================"
  echo "$*"
  echo "================================================================"
}

run() {
  echo
  echo "--- $*"
  bash -c "$*" 2>&1 || true
}

have() { command -v "$1" >/dev/null 2>&1; }

banner "BASIC"
run "date -Is"
run "hostnamectl || true"
run "uname -a"
run "cat /etc/os-release || true"
run "id"
run "uptime || true"
run "df -hT || true"
run "free -h || true"
run "python3 --version || true"
run "command -v python3 || true"
run "command -v jq || true"
run "command -v getent || true"
run "command -v timeout || true"

banner "SECURITY BASELINE (SELINUX / FIREWALL)"
run "getenforce 2>/dev/null || true"
run "sestatus 2>/dev/null || true"
run "systemctl status firewalld --no-pager 2>/dev/null || true"
run "nft list ruleset 2>/dev/null | head -n 200 || true"
run "iptables -S 2>/dev/null | head -n 200 || true"

banner "KERNEL / CGROUP / LSM / BTF"
run "cat /proc/cmdline || true"
run "if [[ -e /sys/fs/cgroup/cgroup.controllers ]]; then echo 'cgroup=v2'; else echo 'cgroup=v1'; fi"
run "cat /sys/kernel/security/lsm 2>/dev/null || true"
run "ls -l /sys/kernel/btf/vmlinux 2>/dev/null || true"
run "sysctl kernel.unprivileged_bpf_disabled 2>/dev/null || true"
run "sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null || true"
run "sysctl net.ipv6.conf.default.disable_ipv6 2>/dev/null || true"

banner "KERNEL CONFIG CHECK (BEST-EFFORT)"
KCFG=""
if [[ -f "/boot/config-$(uname -r)" ]]; then
  KCFG="/boot/config-$(uname -r)"
elif [[ -f "/proc/config.gz" ]]; then
  KCFG="/proc/config.gz"
fi

echo "--- kernel config source: ${KCFG:-NOT_FOUND}"
if [[ -n "${KCFG}" ]]; then
  if [[ "${KCFG}" == "/proc/config.gz" ]]; then
    have zcat || run "dnf -y install gzip || true"
    CFG_CMD="zcat /proc/config.gz"
  else
    CFG_CMD="cat ${KCFG}"
  fi

  for k in \
    CONFIG_BPF \
    CONFIG_BPF_SYSCALL \
    CONFIG_BPF_JIT \
    CONFIG_DEBUG_INFO_BTF \
    CONFIG_BPF_LSM \
    CONFIG_LSM \
    CONFIG_BPF_STREAM_PARSER \
    CONFIG_BPF_KPROBE_OVERRIDE \
    CONFIG_FUNCTION_ERROR_INJECTION \
    CONFIG_CGROUPS \
    CONFIG_CGROUP_BPF \
    CONFIG_TLS \
    CONFIG_IPV6
  do
    echo
    echo "--- ${k}"
    bash -c "${CFG_CMD} | grep -E \"^${k}(=| )\" | head -n 5" 2>&1 || true
  done
fi

banner "NETWORK (ADDR/ROUTE/PORTS)"
run "ip -br addr || true"
run "ip route || true"
run "ip rule || true"
run "ss -lntup || true"
run "ss -tunap | head -n 80 || true"

banner "DNS / RESOLVER"
run "readlink -f /etc/resolv.conf || true"
run "cat /etc/resolv.conf || true"
run "have resolvectl && resolvectl status || true"
run "have systemd-resolve && systemd-resolve --status || true"
run "ps -ef | egrep -i 'systemd-resolved|named|unbound|dnsmasq|NetworkManager' | grep -v egrep || true"
run "ss -lunp | egrep ':53\\b' || true"

banner "TETRAGON ENTERPRISE (SYSTEMD)"
run "systemctl status tetragon-enterprise --no-pager || true"
run "ls -la /etc/tetragon 2>/dev/null || true"
run "ls -la /etc/tetragon/tetragon.conf.d 2>/dev/null || true"
run "ls -la /etc/tetragon/tetragon.tp.d 2>/dev/null || true"
run "command -v tetragon || true"
run "command -v tetra || true"
run "tetra version 2>/dev/null || true"
run "tetragon --version 2>/dev/null || true"
run "sudo journalctl -u tetragon-enterprise --no-pager -n 200 || true"

banner "TETRABLOCKER (SYSTEMD / CONFIG DISCOVERY)"
run "command -v tetrablocker || true"
run "systemctl status tetrablocker.service --no-pager 2>/dev/null || true"
run "systemctl cat tetrablocker.service 2>/dev/null || true"
run "sudo journalctl -u tetrablocker.service --no-pager -n 200 2>/dev/null || true"

# Try common config locations; do not fail if missing.
for p in \
  /etc/tetrablocker.conf \
  /etc/tetrablocker/tetrablocker.conf \
  /usr/local/etc/tetrablocker.conf \
  /usr/local/etc/tetrablocker/tetrablocker.conf
do
  if [[ -f "$p" ]]; then
    banner "FOUND tetrablocker.conf: $p"
    run "sed -n '1,200p' '$p'"
  fi
done

for p in \
  /etc/allowlist-seed.json \
  /etc/tetrablocker/allowlist-seed.json \
  /usr/local/etc/allowlist-seed.json \
  /usr/local/etc/tetrablocker/allowlist-seed.json
do
  if [[ -f "$p" ]]; then
    banner "FOUND allowlist-seed.json: $p"
    run "sed -n '1,260p' '$p'"
  fi
done

banner "TETRA CLI SANITY (EVENT PIPELINE)"
if have tetra; then
  run "timeout 5 sudo tetra status 2>/dev/null || true"
  run "timeout 3 sudo tetra getevents -o compact | head -n 30 || true"
  run "timeout 3 sudo tetra getevents | head -n 5 || true"

  # Show a few raw JSON events for dns/connect for field inspection.
  run "timeout 3 sudo tetra getevents | jq -c 'select(.process_dns != null) | {bin:.process_dns.process.binary, rcode:.process_dns.dns.return_code, names:.process_dns.dns.names, ips:(.process_dns.dns.ips // []), qtypes:(.process_dns.dns.query_types // []), dst:(.process_dns.socket.destination_ip + \":\" + (.process_dns.socket.destination_port|tostring))}' | head -n 8 || true"
  run "timeout 3 sudo tetra getevents | jq -c 'select(.process_connect != null) | {bin:.process_connect.process.binary, proto:.process_connect.socket.protocol, dst:(.process_connect.socket.destination_ip + \":\" + (.process_connect.socket.destination_port|tostring))}' | head -n 8 || true"

  # Actively trigger a successful DNS lookup and confirm dns.ips is populated (1.18+ path).
  if have getent && have timeout && have jq; then
    banner "DNS ANSWER IP SANITY (EXPECT dns.ips NON-EMPTY)"
    run "sudo bash -c '(sleep 0.2; getent ahosts example.com >/dev/null) & timeout 3 tetra getevents | jq -c \"select(.process_dns != null and (.process_dns.dns.return_code // -1) == 0 and ((.process_dns.dns.ips // []) | length) > 0) | {bin:.process_dns.process.binary, names:.process_dns.dns.names, ips:.process_dns.dns.ips, dst:(.process_dns.socket.destination_ip + \":\" + (.process_dns.socket.destination_port|tostring))}\" | head -n 6' || true"
  fi

  run "sudo tetra tracingpolicy list 2>/dev/null || true"
fi

banner "AGENTS / MUST-HAVE SERVICES (GUESS)"
run "systemctl list-unit-files | egrep -i 'amazon-ssm-agent|cloudwatch|splunk|chronyd|ntpd|proxy|vpn|containerd|docker' || true"
run "ps -ef | egrep -i 'amazon-ssm-agent|cloudwatch|splunk|chronyd|ntpd|proxy|vpn|containerd|dockerd' | grep -v egrep || true"
run "rpm -qa | egrep -i 'tetragon|splunk|amazon-ssm-agent|cloudwatch|chrony|dnsmasq|bind|unbound|containerd|docker' || true"

banner "ENV (PROXY)"
run "env | egrep -i '^(http|https|no)_proxy=' || true"

banner "DONE"
echo "If you plan to redact IPs/hostnames, do it now before sharing."

