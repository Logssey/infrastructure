# 12. 관측성

> 구축 전 설계 문서다. 실제 구성과 다를 수 있으며, 구축 후 갱신한다.

## 참고 문서

| 항목 | 링크 |
| --- | --- |
| kube-prometheus-stack | https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack |
| Loki Helm (커뮤니티) | https://github.com/grafana-community/helm-charts/tree/main/charts/loki |
| Loki Monolithic 설치 | https://grafana.com/docs/loki/latest/setup/install/helm/install-monolithic/ |
| Loki 배포 모드 | https://grafana.com/docs/loki/latest/get-started/deployment-modes/ |
| Grafana Alloy | https://grafana.com/docs/alloy/latest/ |
| Alloy Helm | https://github.com/grafana/helm-charts/tree/main/charts/alloy |
| Prometheus 저장소 | https://prometheus.io/docs/prometheus/latest/storage/ |

---

## 구성

| 컴포넌트 | 차트 | 버전 | 역할 |
| --- | --- | --- | --- |
| kube-prometheus-stack | `prometheus-community` | 91.8.2 (Operator v0.94.1) | 메트릭 수집·저장, 대시보드, 알림 |
| Loki | `grafana-community` | 18.13.7 (Loki 3.7.8) | 로그 저장 |
| Alloy | `grafana` | 1.13.0 (v1.20.0) | 로그 수집 |

Grafana 는 kube-prometheus-stack 에 포함되어 있다. 별도로 설치하지 않는다.

```
             ┌─ node-exporter ─┐
메트릭       ├─ kube-state-metrics ─┤→ Prometheus → ┐
             └─ 애플리케이션 /metrics ─┘              │
                                                    ├→ Grafana
로그         컨테이너 로그 → Alloy → Loki → S3 ──────┘
```

---

## 왜 이 조합인가

### 로그 수집기 — Alloy

기존 선택지가 모두 수명을 다했다.

| 도구 | 상태 |
| --- | --- |
| Promtail | **2026-03-02 EOL** |
| Grafana Agent | **2025-11-01 EOL** |
| **Alloy** | **후계자.** OpenTelemetry Collector 배포판 |

선택지가 사실상 하나다.

### 메트릭은 Prometheus 가 직접 긁는다

Alloy 는 메트릭도 수집할 수 있다. 에이전트를 하나로 줄일 수 있다는 점에서
매력적이고, Grafana 쪽 문서도 그 방향을 권한다.

**그런데 kube-prometheus-stack 은 수집기가 아니라 묶음이다.**

| 포함 | 역할 |
| --- | --- |
| Prometheus Operator | ServiceMonitor·PodMonitor CRD |
| Prometheus | 스크레이핑 + 저장 |
| node-exporter | 노드 메트릭 |
| kube-state-metrics | 쿠버네티스 객체 상태 |
| Grafana | 대시보드 수십 개 내장 |
| Alertmanager | 알림 |
| 기본 알림 규칙 | 수백 개 |

메트릭 수집을 Alloy 로 옮기면 **이 생태계를 버리게 된다.**
대시보드와 알림 규칙을 직접 만들어야 하고, ServiceMonitor 로 스크레이핑
대상을 선언하는 쿠버네티스 표준 방식에서도 멀어진다.

Alloy 에 `prometheus.operator.servicemonitors` 컴포넌트가 있어
ServiceMonitor 를 읽을 수는 있으나, 그렇게까지 해서 얻는 것이
에이전트 하나 줄이는 것뿐이다.

**메트릭은 Prometheus, 로그 수집만 Alloy 로 간다.**

| 판단 | 내용 |
| --- | --- |
| 에이전트 하나로 통합 | OTel 중심으로 가거나 트레이스까지 다룰 때 |
| **둘로 나눔** | **대시보드·알림 생태계를 쓸 때. 현재 규모에 맞음** |

### Loki 저장소 — S3

| 방식 | 내용 |
| --- | --- |
| filesystem (PVC) | 단순. Monolithic 모드면 동작 |
| **S3** | **프로덕션 권장** |

공식 문서는 단일 바이너리 설치에 filesystem 을 허용하되
**프로덕션에는 오브젝트 스토리지를 권한다.**

우리 규모(하루 수백 MB)에서는 filesystem 도 충분하고 비용 차이도 작다.
그럼에도 S3 를 택한 이유는 둘이다.

| 이유 | 내용 |
| --- | --- |
| 나중에 옮기려면 데이터 이관 | filesystem → S3 전환 시 기존 로그를 버리거나 옮겨야 한다 |
| S3 모듈이 어차피 필요 | 이미지 업로드 버킷을 Terraform 으로 관리해야 한다 |

### Loki 배포 모드 — Monolithic

| 모드 | Pod 수 | 용도 |
| --- | --- | --- |
| **Monolithic** | 1 | 하루 수십 GB 이하 |
| SimpleScalable | 9 | 중규모. **Loki 4.0 에서 제거 예정** |
| Distributed | 다수 | 대규모 |

**커뮤니티 차트 18.x 부터 Monolithic 이 기본값이다.**
SimpleScalable 은 deprecated 되었으므로 선택지에서 뺀다.

차트 12.0.0 에서 `SingleBinary` 가 `Monolithic` 으로 개명됐다.
values 키는 여전히 `singleBinary` 이지만 `deploymentMode` 값은 `Monolithic` 이다.

---

## 배치와 리소스

### 배치

Worker 3대에 배치한다. Control Plane 은 Taint 로 막혀 있고
메모리도 75~78% 로 여유가 없다.

```
cp-a      2233Mi / 75%
cp-c      2319Mi / 78%
cp-d      2160Mi / 72%
worker-a  2728Mi / 39%
worker-c  2140Mi / 30%
worker-d  2613Mi / 37%
```

Worker 는 t3.large(8GiB)이므로 노드당 4GiB 이상 남는다.

### 예상 사용량

| 컴포넌트 | requests | 배치 |
| --- | --- | --- |
| Prometheus | 1Gi / 300m | Deployment 1 |
| Grafana | 256Mi / 100m | Deployment 1 |
| Alertmanager | 128Mi / 50m | Deployment 1 |
| kube-state-metrics | 128Mi / 50m | Deployment 1 |
| node-exporter | 64Mi / 20m | DaemonSet ×6 |
| Loki | 512Mi / 200m | StatefulSet 1 |
| Alloy | 128Mi / 50m | DaemonSet ×6 |

**합계 약 3.2Gi.** Worker 전체 여유(약 13Gi)의 4분의 1이다.

Prometheus 와 Loki 가 같은 노드에 뜨면 그 노드만 빡빡해진다.
`podAntiAffinity` 로 분산하거나, requests 를 정확히 잡아 스케줄러가
판단하게 한다. 후자를 택한다. 노드가 셋뿐이라 강제 분산은 유연성을 줄인다.

### 선행 작업 — Cilium QoS

**`cilium-envoy` 와 `hubble-relay` 가 BestEffort QoS 다.**

```bash
kubectl -n kube-system get pods \
  -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass' | grep -i "envoy\|hubble"
```

```
cilium-envoy-987tk      BestEffort
...
hubble-relay-...        BestEffort
```

BestEffort 는 **메모리 압박 시 가장 먼저 축출된다.**
관측성을 올려 메모리 사용량이 늘면 이들이 먼저 죽는다.

**`cilium-envoy` 가 죽으면 L7 NetworkPolicy 가 동작하지 않는다.**
그런데 기본 통신은 정상이라 드러나지 않는다.
`docs/troubleshooting/07-iptables-corruption-l7.md` 와 같은 양상이다.

실측은 아래와 같다.

```
cilium-envoy      54Mi
hubble-relay      62Mi
```

requests 를 주어 Burstable 로 올린다.

```yaml
# infrastructure/k8s/platform/cilium/values.yaml
envoy:
  resources:
    requests:
      cpu: 50m
      memory: 128Mi

hubble:
  relay:
    resources:
      requests:
        cpu: 20m
        memory: 64Mi
```

**limits 는 두지 않는다.** Guaranteed 까지 갈 필요는 없고,
requests 만 있으면 축출 우선순위에서 BestEffort 보다 뒤로 밀린다.

**관측성보다 먼저 적용한다.**

---

## Prometheus

### 보존과 저장소

| 항목 | 값 | 근거 |
| --- | --- | --- |
| 보존 기간 | 15일 | 차트 기본값. 2주 추세면 충분 |
| PVC | 50Gi gp3 | 차트 기본값 |
| StorageClass | `gp3` | EBS CSI Driver |

**실사용은 10~15Gi 정도로 예상한다.**
노드 6대, Pod 66개 규모에서 15일이면 그 정도다.

그럼에도 50Gi 를 잡는 이유는 **gp3 볼륨을 나중에 줄일 수 없기 때문이다.**
늘리는 것은 온라인으로 되지만 줄이려면 새 볼륨을 만들어 옮겨야 한다.
월 $4 차이라 여유를 둔다.

### 수집 대상

Operator 가 `ServiceMonitor` 와 `PodMonitor` CRD 를 감시한다.
대상을 추가하려면 CR 을 만들면 되고, Prometheus 설정을 직접 고치지 않는다.

기본으로 수집되는 것.

| 대상 | 경로 |
| --- | --- |
| 노드 | node-exporter |
| 쿠버네티스 객체 | kube-state-metrics |
| Control Plane | apiserver, scheduler, controller-manager, etcd |
| kubelet | cAdvisor 포함 |

애플리케이션 메트릭은 별도로 붙인다. Spring Boot Actuator 의
`/actuator/prometheus` 를 노출하고 ServiceMonitor 를 만든다.
현재 actuator 는 health 만 열어두었으므로 **백엔드 설정 변경이 필요하다.**

### Control Plane 수집의 제약

kube-prometheus-stack 은 Control Plane 컴포넌트를 수집하려 하지만
**self-managed 클러스터에서는 기본 설정으로 실패하는 경우가 많다.**

| 컴포넌트 | 문제 |
| --- | --- |
| kube-scheduler | 기본 바인드 주소가 127.0.0.1 |
| kube-controller-manager | 같음 |
| etcd | **External etcd 라 별도 처리 필요** |

etcd 가 Control Plane 밖의 독립 노드에 있으므로
차트의 기본 `serviceMonitor` 로는 잡히지 않는다.

| 안 | 내용 |
| --- | --- |
| A | etcd 메트릭 수집을 끈다 |
| B | Endpoints 를 수동으로 만들어 연결 |

etcd 메트릭은 클러스터 건강에 중요하므로 B 가 바람직하나,
**etcd 클라이언트 인증서가 필요하다.** 1차 구축에서는 A 로 두고
확장 항목으로 남긴다.

---

## Loki

### 설정

```yaml
deploymentMode: Monolithic

loki:
  commonConfig:
    replication_factor: 1
  schemaConfig:
    configs:
      - from: "2026-10-01"
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  storage:
    type: s3
    bucketNames:
      chunks: logssey-prod-loki-chunks
      ruler: logssey-prod-loki-ruler
    s3:
      region: ap-northeast-1
      s3ForcePathStyle: false
      insecure: false
  limits_config:
    retention_period: 720h    # 30일

singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 10Gi
    storageClass: gp3

# MinIO 서브차트는 2026-10-31 제거 예정이다.
# S3 를 쓰므로 비활성화한다.
minio:
  enabled: false

# SimpleScalable 컴포넌트를 쓰지 않는다
read:
  replicas: 0
write:
  replicas: 0
backend:
  replicas: 0
```

### 짚어둘 점

**기본 버킷 이름을 쓰지 않는다.**

공식 문서가 명시적으로 경고한다.

> S3 스토리지로 Loki 를 배포할 때 기본 버킷 이름
> (`chunk`, `ruler`, `admin`)을 **쓰지 마라.**

2024년에 보안 이슈가 있었다. 전역 고유한 이름을 쓴다.

**`admin` 버킷은 만들지 않는다.** Grafana Enterprise Logs 전용이다.

**`replication_factor: 1`** 은 단일 replica 구성이라 그렇다.
2 이상으로 늘리면 그에 맞춰 올린다.

**PVC 가 여전히 필요하다.** S3 에 청크를 저장해도
WAL(write-ahead log)과 인덱스 캐시는 로컬 디스크를 쓴다.

**18.3.0 부터 `enableStatefulSetAutoDeletePVC` 기본값이 false 다.**
StatefulSet 을 지워도 PVC 가 남는다. 의도된 변경이며 그대로 둔다.

### 인증

**액세스 키를 넣지 않는다.** 노드 IAM Role 에 S3 권한을 주면
AWS SDK 의 기본 자격증명 체인이 찾아 쓴다.

```yaml
    s3:
      region: ap-northeast-1
      # accessKeyId, secretAccessKey 생략
```

ESO 와 같은 방식이다. **IRSA 가 없어 노드 Role 을 쓰는 한계**도 동일하다.

---

## Alloy

### 배포 형태

DaemonSet 으로 노드마다 하나씩 띄운다.
`/var/log/pods` 를 읽어야 하므로 hostPath 마운트가 필요하다.

```yaml
controller:
  type: daemonset

alloy:
  mounts:
    varlog: true
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
```

### 설정

Alloy 는 자체 설정 언어를 쓴다. ConfigMap 으로 주입한다.

```
discovery.kubernetes "pods" {
  role = "pod"
}

discovery.relabel "pods" {
  targets = discovery.kubernetes.pods.targets
  // 네임스페이스, Pod 이름, 컨테이너 이름을 라벨로
}

loki.source.kubernetes "pods" {
  targets    = discovery.relabel.pods.output
  forward_to = [loki.write.default.receiver]
}

loki.write "default" {
  endpoint {
    url = "http://loki.monitoring.svc:3100/loki/api/v1/push"
  }
}
```

**라벨을 과하게 붙이지 않는다.**
Loki 는 라벨 조합마다 스트림을 만든다. 라벨이 많으면 스트림이 폭증하고
쿼리 성능과 저장 효율이 떨어진다.

Grafana 의 Kubernetes Monitoring 차트가 v4 에서 이 문제를 고쳤다.
v3 은 모든 Pod 라벨을 붙인 뒤 걸러냈는데, Alloy 가 수백 개 라벨을
메모리에 올렸다가 버리느라 메모리 문제가 보고됐다.

**필요한 것만 붙인다.**

| 라벨 | 용도 |
| --- | --- |
| `namespace` | 서비스 구분 |
| `pod` | 인스턴스 구분 |
| `container` | 사이드카 구분 |
| `app` | 애플리케이션 그룹 |

---

## Grafana

### 데이터소스

kube-prometheus-stack 이 Prometheus 를 자동 연결한다.
Loki 는 추가해야 한다.

```yaml
grafana:
  additionalDataSources:
    - name: Loki
      type: loki
      url: http://loki.monitoring.svc:3100
      access: proxy
```

### 관리자 비밀번호

**Secrets Manager 에 두고 ESO 로 주입한다.** 기존 방식과 같다.

```yaml
grafana:
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
```

시크릿은 `logssey/prod/grafana` 로 만든다.
애플리케이션 시크릿(`reused/prod/*`)과 접두사를 나누어
플랫폼 컴포넌트임을 드러낸다.

### 외부 노출

| 안 | 내용 |
| --- | --- |
| A | 포트포워딩만 |
| B | **`grafana.re-used.store` + GitHub OAuth** |

Argo CD 는 A 로 두었으나 Grafana 는 **자주 보게 되므로** B 로 간다.

경로는 기존 것을 재사용한다.

```
브라우저 → CloudFront → Public NLB → Envoy Gateway → Grafana
```

준비할 것.

| 항목 | 내용 |
| --- | --- |
| Route 53 | `grafana.re-used.store` A 레코드 (CloudFront alias) |
| CloudFront | 기존 distribution 의 `aliases` 에 추가 |
| 인증서 | 와일드카드 보유 |
| HTTPRoute | hostname `grafana.re-used.store` |
| GitHub OAuth App | 조직 설정에서 생성 |

**CloudFront 를 거치는 이유**는 WAF 를 그대로 적용받기 위함이다.
NLB 리스너를 따로 열면 WAF 가 빠진다.

**`re-used.store` 와 `grafana.re-used.store` 는 다른 호스트다.**
기존 distribution 의 `aliases` 에 추가해야 한다.
Host 전달 정책은 이미 적용되어 있어(`11-cloudfront-host-header.md`)
HTTPRoute 매칭에 문제가 없다.

### GitHub OAuth

```yaml
grafana:
  grafana.ini:
    server:
      root_url: https://grafana.re-used.store
    auth.github:
      enabled: true
      allow_sign_up: true
      allowed_organizations: Logssey
      client_id: $__file{/etc/secrets/oauth/client-id}
      client_secret: $__file{/etc/secrets/oauth/client-secret}
    auth.anonymous:
      enabled: false
```

**`allowed_organizations` 를 반드시 둔다.**
없으면 GitHub 계정이 있는 누구나 로그인할 수 있다.

**기본 admin 계정은 남겨둔다.** OAuth 가 깨졌을 때 들어갈 경로가 필요하다.
비밀번호는 Secrets Manager 에 있고 외부에서 추측할 수 없다.

---

## Argo CD 관리 구조

관측성은 **`gitops` 레포에서 Argo CD 가 관리한다.**
"Argo CD 없이도 있어야 하는가" 기준에서 없어도 클러스터는 동작하기 때문이다.

### ApplicationSet 을 하나 더 만든다

기존 것은 `apps/*` 를 스캔해 전부 `reused` 네임스페이스로 보낸다.
관측성은 `monitoring` 네임스페이스이므로 별도가 필요하다.

```
apps/*        → namespace: reused       (기존)
platform/*    → namespace: monitoring   (신규)
```

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/Logssey/gitops
        revision: main
        directories:
          - path: platform/*
  template:
    metadata:
      name: '{{path.basename}}'
    spec:
      project: platform
      source:
        repoURL: https://github.com/Logssey/gitops
        targetRevision: main
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: monitoring
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
```

**`ServerSideApply=true` 가 필요하다.**
kube-prometheus-stack 의 CRD 는 어노테이션 크기 제한(262144 바이트)을
넘어 client-side apply 로는 적용되지 않는다.

### AppProject 도 나눈다

`reused` 프로젝트는 클러스터 범위 리소스로 Namespace 만 허용한다.
**관측성은 그보다 훨씬 많이 필요하다.**

| 리소스 | 용도 |
| --- | --- |
| CustomResourceDefinition | ServiceMonitor, PrometheusRule 등 |
| ClusterRole·ClusterRoleBinding | 전체 네임스페이스 조회 |
| MutatingWebhookConfiguration | Operator admission |
| Namespace | CreateNamespace |

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  sourceRepos:
    - https://github.com/Logssey/gitops
  destinations:
    - server: https://kubernetes.default.svc
      namespace: monitoring
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
```

**`clusterResourceWhitelist` 를 `*` 로 여는 것은 넓다.**
개별 나열이 최소 권한에 맞으나, Operator 가 만드는 리소스 종류를
사전에 전부 파악하기 어렵고 차트 업그레이드마다 바뀐다.

프로젝트를 나눈 것 자체가 격리다. `reused` 프로젝트는 여전히
Namespace 만 허용하므로 애플리케이션이 클러스터 범위 리소스를
만들 수 없다.

### 디렉터리 구조

```
gitops/
  apps/
    reused-api/
    reused-chat/
    reused-web/
  platform/
    kube-prometheus-stack/
      Chart.yaml          # 의존성으로 외부 차트 참조
      values.yaml
    loki/
    alloy/
  argocd/
    appproject.yaml
    appproject-platform.yaml
    applicationset.yaml
    applicationset-platform.yaml
```

외부 차트는 **의존성으로 참조하고 버전을 고정한다.**

```yaml
apiVersion: v2
name: kube-prometheus-stack
version: 0.1.0
dependencies:
  - name: kube-prometheus-stack
    version: "91.8.2"
    repository: https://prometheus-community.github.io/helm-charts
```

범위 지정자(`^91.0.0`)를 쓰지 않는다.
같은 Git 리비전이 다른 매니페스트를 만들어내면 GitOps 가 성립하지 않는다.

---

## S3

### 버킷

| 버킷 | 용도 | 상태 |
| --- | --- | --- |
| `logssey-prod-s3-images` | 이미지 업로드 | **콘솔 생성. Terraform 으로 import** |
| `logssey-prod-loki-chunks` | 로그 청크·인덱스 | 신규 |
| `logssey-prod-loki-ruler` | 알림 규칙 | 신규 |

`modules/s3` 를 만들어 셋을 함께 관리한다.

### 공통 설정

| 항목 | 값 |
| --- | --- |
| 퍼블릭 차단 | 4종 전부 |
| 암호화 | SSE-S3 (AES256), Bucket Key 활성 |
| 버저닝 | 비활성 |

**버저닝을 끄는 이유**는 두 버킷 모두 재생성 가능한 데이터를 담기 때문이다.
이미지는 사용자가 다시 올릴 수 있고, 로그는 보존 기간이 지나면 지운다.
켜면 삭제해도 이전 버전이 남아 비용이 늘고 수명주기 규칙이 복잡해진다.

### 버킷별 차이

| 항목 | images | loki-chunks | loki-ruler |
| --- | --- | --- | --- |
| CORS | 필요 | — | — |
| 수명주기 | `pending/` 1일 | 30일 만료 | — |

**이미지 버킷은 Presigned URL 방식**이라 브라우저가 S3 로 직접 PUT 한다.
CORS 가 없으면 동작하지 않는다.

**`pending/` 규칙**은 업로드됐으나 검증·승격되지 않은 고아 객체를 지운다.
백엔드가 `pending/` 에 올리고 검증 후 `verified/` 로 복사하는 구조다.

**Loki 보존은 두 곳에서 설정한다.**

| 위치 | 역할 |
| --- | --- |
| Loki `retention_period` | Loki 가 논리적으로 만료 처리 |
| S3 수명주기 | 실제 객체 삭제 |

Loki 의 compactor 가 삭제를 수행하지만, 누락된 객체가 남을 수 있어
S3 수명주기를 안전망으로 둔다. **S3 쪽을 더 길게** 잡는다(35일).

### 기존 버킷 import

Terraform 1.5 부터 `import` 블록을 쓸 수 있다.

```hcl
import {
  to = module.s3.aws_s3_bucket.images
  id = "logssey-prod-s3-images"
}
```

**CLI 의 `terraform import` 보다 낫다.**
`terraform plan` 에서 결과를 미리 볼 수 있고, 코드와 실제 설정이 다르면
변경 항목이 함께 표시된다. 그것을 보고 코드를 맞춘 뒤 apply 한다.

현재 설정은 아래와 같다. 코드를 여기에 맞춘다.

```
버저닝      비활성
암호화      SSE-S3 (AES256), BucketKeyEnabled: true
퍼블릭 차단  4종 전부
CORS        Content-Type / PUT / re-used.store, www.re-used.store / 3000초
수명주기     pending/ 접두사 1일 후 만료
```

`BlockedEncryptionTypes` (SSE-C 차단)도 설정되어 있다.
**Terraform provider 가 지원하는지 확인이 필요하다.**
지원하지 않으면 import 후 plan 에 차이가 남거나 무시된다.

### IAM

노드 IAM Role 에 Loki 버킷 접근 권한을 추가한다.

```hcl
Action = [
  "s3:GetObject",
  "s3:PutObject",
  "s3:DeleteObject",
  "s3:ListBucket",
]
Resource = [
  aws_s3_bucket.loki_chunks.arn,
  "${aws_s3_bucket.loki_chunks.arn}/*",
  aws_s3_bucket.loki_ruler.arn,
  "${aws_s3_bucket.loki_ruler.arn}/*",
]
```

**현재 노드 Role 에 `AmazonS3FullAccess` 가 콘솔로 부착되어 있다.**
모든 버킷에 대한 전체 권한이므로 범위를 좁혀야 한다.
이 작업과 함께 정리한다.

---

## 설치 순서

| 순서 | 작업 | 위치 |
| --- | --- | --- |
| 1 | `modules/s3` 작성, 이미지 버킷 import, Loki 버킷 생성 | `infrastructure` |
| 2 | 노드 IAM Role 에 S3 권한 (범위 축소 포함) | `infrastructure` |
| 3 | Cilium QoS 수정 | `infrastructure` |
| 4 | AppProject·ApplicationSet 추가 | `gitops` |
| 5 | kube-prometheus-stack | `gitops` |
| 6 | Loki | `gitops` |
| 7 | Alloy | `gitops` |
| 8 | Grafana 데이터소스·노출 | `gitops` + `infrastructure` |

**3번을 관측성보다 먼저** 한다. 메모리 압박이 생긴 뒤에는 늦다.

**5번과 6번 사이에 간격을 둔다.** Prometheus 가 안정적으로 뜨는지
확인한 뒤 Loki 를 올린다. 둘을 동시에 올리면 리소스 문제가 생겼을 때
원인을 구분하기 어렵다.

---

## 검증

### Prometheus

```bash
kubectl -n monitoring get pods
kubectl -n monitoring get pvc
```

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

`http://localhost:9090/targets` 에서 수집 대상 상태를 본다.
Control Plane 관련 항목이 실패할 수 있다. 위의 제약 절 참조.

### Loki

```bash
kubectl -n monitoring logs -l app.kubernetes.io/name=loki --tail=30
```

S3 접근 실패는 여기 찍힌다.

```bash
aws s3 ls s3://logssey-prod-loki-chunks/ --region ap-northeast-1
```

청크가 쌓이기까지 몇 분 걸린다.

### Alloy

```bash
kubectl -n monitoring get ds
kubectl -n monitoring logs -l app.kubernetes.io/name=alloy --tail=30
```

### Grafana

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Explore 에서 Loki 데이터소스를 골라 쿼리한다.

```
{namespace="reused"} |= "error"
```

### 리소스 영향

관측성을 올린 뒤 노드 상태를 다시 확인한다.

```bash
kubectl top nodes
```

```bash
kubectl -n kube-system get pods \
  -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass' | grep -i "envoy\|hubble"
```

`Burstable` 로 바뀌어 있어야 한다.

---

## 비용

| 항목 | 월 (USD) |
| --- | --- |
| Prometheus PVC 50Gi gp3 | 약 4 |
| Loki PVC 10Gi gp3 | 약 1 |
| S3 (로그 10GB 가정) | 약 0.3 |
| S3 요청 | 약 0.1 |
| **합계** | **약 5.5** |

EC2 추가는 없다. 기존 Worker 에 배치한다.

---

## 미해결 항목

| 항목 | 내용 |
| --- | --- |
| etcd 메트릭 | External etcd 라 수동 Endpoints·인증서 필요 |
| 애플리케이션 메트릭 | Spring Boot actuator 에 `prometheus` 엔드포인트 노출 필요 |
| Alertmanager 수신처 | Slack·Discord 미연동. 알림이 쌓이기만 한다 |
| 로그 보존 검증 | compactor 가 실제로 삭제하는지 30일 후 확인 |
| 노드 Role 권한 | `AmazonS3FullAccess` 범위 축소 |

---

## 확장 항목

| 항목 | 시점 |
| --- | --- |
| Alertmanager → Slack·Discord | 알림 대응 체계를 갖출 때 |
| etcd 메트릭 수집 | 인증서 배포 절차를 정할 때 |
| Tempo (트레이스) | 분산 추적이 필요할 때 |
| Pyroscope (프로파일링) | 성능 분석이 필요할 때 |
| Thanos·Mimir | 장기 보존이나 멀티클러스터가 필요할 때 |
| Loki SimpleScalable | 로그량이 하루 수십 GB 를 넘을 때 |
| Alloy 로 메트릭 통합 | OTel 중심으로 전환할 때 |
| Prometheus HA | 단일 인스턴스 장애를 감수할 수 없을 때 |