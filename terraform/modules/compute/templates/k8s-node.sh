#!/bin/bash
set -euxo pipefail

# ─────────────────────────────────────────────
# Kubernetes 노드 사전 설정
# Control Plane / etcd / Worker 공통
#
# 실행 로그: /var/log/cloud-init-output.log
# 상태 확인: cloud-init status --long
# ─────────────────────────────────────────────

# swap 비활성화
# kubelet은 swap이 켜져 있으면 기동을 거부한다.
# \b 는 단어 경계. 공백·탭 구분을 모두 잡는다.
# fstab 은 부팅 필수 파일이므로 .bak 백업을 남긴다.
swapoff -a
sed -i.bak '/\bswap\b/s/^/#/' /etc/fstab

# 커널 모듈
# overlay      : containerd의 overlayfs 스토리지 드라이버
# br_netfilter : 브리지 트래픽을 iptables가 볼 수 있게 함
cat <<'MODULES' > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
MODULES

modprobe overlay
modprobe br_netfilter

# sysctl
# bridge-nf-call-iptables : Pod 간 통신 시 iptables 규칙 적용
# ip_forward              : 노드 간 패킷 포워딩
cat <<'SYSCTL' > /etc/sysctl.d/99-k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL

sysctl --system

# 시간 동기화
# 노드 간 시간이 어긋나면 etcd 인증서 검증이 실패한다.
timedatectl set-ntp true

# 완료 표식
# Kubespray 실행 전 전 노드 확인에 사용한다.
touch /var/log/logssey-init-done
