#!/bin/bash
set -euxo pipefail

# ─────────────────────────────────────────────
# Redis 노드 초기 설정
#
# 설치만 수행하고 상세 설정(requirepass, maxmemory, AOF)은
# SSM 접속 후 수동으로 진행한다.
# 비밀번호를 user_data에 넣으면 IMDS로 평문 노출된다.
# ─────────────────────────────────────────────

apt-get update
apt-get install -y redis-server

# 기동은 설정 완료 후 수동으로 한다.
systemctl stop redis-server
systemctl disable redis-server
