#!/bin/bash
set -euxo pipefail

# ─────────────────────────────────────────────
# Redis 노드 초기 설정
#
# 설치만 수행하고 상세 설정(ACL, maxmemory, AOF)은
# SSM 접속 후 수동으로 진행한다.
# 비밀번호를 user_data에 넣으면 IMDS로 평문 노출된다.
#
# 설정 절차는 docs/09-redis.md 참조
# ─────────────────────────────────────────────

apt-get update
apt-get install -y unzip curl gnupg lsb-release

# ─────────────────────────────────────────────
# Redis 는 공식 저장소에서 설치한다.
#
# Ubuntu 24.04 universe 저장소는 7.0.15 에서 멈춰 있다.
# 채팅 게이트웨이가 쓰는 node-redis 는 연결 직후 CLIENT SETINFO 를
# 보내는데, 이 명령은 7.2 에 도입되어 7.0 에서는 실패한다.
#
# 패키지 이름이 다르다. universe 는 redis-server, 공식은 redis 다.
# 둘을 섞으면 systemd 유닛과 설정 경로가 충돌하므로 공식 쪽만 쓴다.
# ─────────────────────────────────────────────
curl -fsSL https://packages.redis.io/gpg \
  | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/redis.list

apt-get update
apt-get install -y redis

# AWS CLI
# Ubuntu 24.04 저장소에서 awscli 패키지가 제거되어 공식 설치 스크립트를 사용한다.
# Parameter Store 에서 Redis 비밀번호를 조회하는 데 필요하다.
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

# 커널 파라미터
# Redis 는 RDB 저장과 AOF 재작성에 fork() 를 사용한다.
# 기본 설정에서는 부모 프로세스만큼의 메모리가 필요하다고 판단해
# 저메모리 상황에서 실패할 수 있다.
echo "vm.overcommit_memory = 1" > /etc/sysctl.d/99-redis.conf
sysctl -p /etc/sysctl.d/99-redis.conf

# 기동은 설정 완료 후 수동으로 한다.
# 기본 설정(bind 127.0.0.1, 인증 없음)으로 뜨는 것을 막는다.
systemctl stop redis-server
systemctl disable redis-server