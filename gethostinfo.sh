#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

banner() {
  echo
  echo "================================================================"
  echo "$*"
  echo "================================================================"
}

run() {
  echo
  echo "--- $*"
  # Run in current shell so functions like "have" work.
  eval "$*" 2>&1 || true
}

have() { command -v "$1" >/dev/null 2>&1; }

tetra_dns_snapshot() {
  echo
  echo "--- tetra dns snapshot (20s)"
  if have tetra && have jq; then
    # Run the whole pipeline under one timeout.
    timeout 20s bash -lc '
      set -o pipefail
      sudo tetra getevents 2>/dev/null \
        | jq -c '"'"'
            select(.process_dns != null)
            | {
                time: .time,
                bin:  .process_dns.process.binary,
                names: (.process_dns.dns.names // []),
                ips:   (.process_dns.dns.ips // []),
                qtypes:(.process_dns.dns.query_types // []),
                rcode: (.process_dns.dns.return_code // null)
              }
          '"'"'
    ' 2>&1 || true
  else
    echo "SKIP: tetra/jq not found"
  fi
}

tetra_connect_snapshot() {
  echo
  echo "--- tetra connect snapshot (20s)"
  if have tetra && have jq; then
    timeout 20s bash -lc '
      set -o pipefail
      sudo tetra getevents 2>/dev/null \
        | jq -c '"'"'
            select(.process_connect != null)
            | {
                time: .time,
                bin:  .process_connect.process.binary,
                proto:(.process_connect.protocol // null),
                src:  ((.process_connect.source_ip // "") + ":" + ((.process_connect.source_port // 0)|tostring)),
                dst:  ((.process_connect.destination_ip // "") + ":" + ((.process_connect.destination_port // 0)|tostring))
              }
          '"'"'
    ' 2>&1 || true
  else
    echo "SKIP: tetra/jq not found"
  fi
}

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
run "command -v timeout || true"

banner "PROXY / ENV (BEST-EFFORT)"
run "env | egrep -i \"^(http|https|no)_proxy=\" || true"
run "sudo -n true 2>/dev/null && echo \"sudo: non-interactive OK\" || echo \"sudo: may prompt\""

banner "KERNEL / CGROUP / LSM / BTF"
run "cat /proc/cmdline || true"
run "if [[ -e /sys/fs/cgroup/cgroup.controllers ]]; then echo 'cgroup=v2'; else echo 'cgroup=v1'; fi"
run "cat /sys/kernel/security/lsm 2>/dev/null || true"
run "ls -l /sys/kernel/btf/vmlinux 2>/dev/null || true"
run "sysctl kernel.unprivileged_bpf_disabled 2>/dev/null || true"
run "sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null || true"
run "ip -6 addr 2>/dev/null || true"
run "ip -6 route 2>/dev/null || true"

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
    if ! have zcat; then
      if have dnf; then
        run "sudo dnf -y install gzip || true"
      elif have yum; then
        run "sudo yum -y install gzip || true"
      fi
    fi
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
    CONFIG_TLS
  do
    echo
    echo "--- ${k}"
    bash -lc "${CFG_CMD} | grep -E \"^${k}(=| )\" | head -n 5" 2>&1 || true
  done
fi

banner "NETWORK (ADDR/ROUTE/PORTS)"
run "ip -br addr || true"
run "ip route || true"
run "ip rule || true"
run "ss -lntup || true"
run "ss -lunp || true"

banner "DNS / RESOLVER"
run "readlink -f /etc/resolv.conf || true"
run "cat /etc/resolv.conf || true"
run "command -v resolvectl >/dev/null 2>&1 && resolvectl status || true"
run "command -v systemd-resolve >/dev/null 2>&1 && systemd-resolve --status || true"
run "ps -ef | egrep -i 'systemd-resolved|named|unbound|dnsmasq|NetworkManager' | grep -v egrep || true"
run "ss -lunp | egrep ':53\\b' || true"

banner "DNF / REPOS (BEST-EFFORT)"
run "ls -la /etc/yum.repos.d 2>/dev/null || true"
run "grep -R \"^[[]\\|^name=\\|^mirrorlist=\\|^baseurl=\\|^metalink=\\|^enabled=\" -n /etc/yum.repos.d 2>/dev/null || true"
run "command -v dnf >/dev/null 2>&1 && dnf repolist -v || true"

banner "CONTAINER RUNTIME (BEST-EFFORT)"
run "command -v containerd || true"
run "command -v dockerd || true"
run "command -v docker || true"
run "command -v podman || true"
run "rpm -qa | egrep -i 'containerd|docker|podman|runc|cri-o' || true"
run "systemctl status containerd --no-pager 2>/dev/null || true"
run "systemctl status docker --no-pager 2>/dev/null || true"

banner "TETRAGON ENTERPRISE (SYSTEMD)"
run "systemctl status tetragon-enterprise --no-pager || true"
run "systemctl cat tetragon-enterprise --no-pager || true"
run "journalctl -u tetragon-enterprise --no-pager -n 120 || true"
run "ls -la /etc/tetragon 2>/dev/null || true"
run "ls -la /etc/tetragon/tetragon.conf.d 2>/dev/null || true"
run "ls -la /etc/tetragon/tetragon.tp.d 2>/dev/null || true"
run "cat /etc/tetragon/tetragon.yaml 2>/dev/null || true"
run "command -v tetragon || true"
run "command -v tetra || true"
run "tetra version 2>/dev/null || true"
run "tetragon --version 2>/dev/null || true"
run "ss -lntp | egrep ':54321\\b' || true"

banner "AWS AGENTS (BEST-EFFORT)"
run "systemctl status amazon-ssm-agent --no-pager 2>/dev/null || true"
run "systemctl cat amazon-ssm-agent --no-pager 2>/dev/null || true"
run "journalctl -u amazon-ssm-agent --no-pager -n 120 2>/dev/null || true"
run "ps -ef | egrep -i 'amazon-ssm-agent|ssm-agent-worker|cloudwatch|splunk|chronyd|ntpd|proxy|vpn' | grep -v egrep || true"

banner "TETRA CLI SANITY (BEST-EFFORT)"
if have tetra; then
  run "timeout 5s sudo tetra status 2>/dev/null || true"
  run "timeout 6s sudo tetra getevents | head -n 30 || true"
  run "timeout 6s sudo tetra getevents | jq -c 'select(.process_dns != null)' | head -n 10 || true"
  run "timeout 6s sudo tetra getevents | jq -c 'select(.process_connect != null)' | head -n 10 || true"
  run "sudo tetra tracingpolicy list 2>/dev/null || true"
  run "sudo tetra debug dns --help 2>/dev/null || true"
fi

banner "TETRA DNS/CONNECT SNAPSHOT (FOR SEED/TRUSTED BINARIES)"
tetra_dns_snapshot
tetra_connect_snapshot

banner "DONE"
echo "If you plan to redact IPs/hostnames, do it now before sharing."
