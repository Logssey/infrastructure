# 08. Envoy Gateway NodePort 고정 — 패치 문법과 롤링 교착

| 항목 | 내용 |
| --- | --- |
| 발생 | 2026-09-22 |
| 단계 | Envoy Gateway 구성 |
| 영향 | Gateway 가 `PROGRAMMED: False` 에서 진행 불가 / 롤링 업데이트 중단 |
| 환경 | Envoy Gateway v1.9.1, Gateway API v1.6.1, Kubernetes 1.35.4 |

NodePort 30080 고정 과정에서 두 건이 발생했다.

---

## 1차 — StrategicMerge 병합 키

### 배경

Public NLB 타겟 그룹이 30080 으로 고정되어 있어 Envoy Service 의
NodePort 도 같은 값이어야 한다. `EnvoyProxy` CRD 의 `envoyService.patch` 로
지정한다.

Envoy Gateway 공식 문서(Customize EnvoyProxy)에 NodePort 고정 예시가 없어
Service 스펙을 보고 패치를 작성했다.

```yaml
envoyService:
  type: NodePort
  patch:
    type: StrategicMerge
    value:
      spec:
        ports:
          - name: http-80
            nodePort: 30080
```

### 증상

`kubectl apply` 는 성공했으나 Service 가 바뀌지 않았다.

```
NAME                                     TYPE           EXTERNAL-IP   PORT(S)
envoy-envoy-gateway-system-eg-5391c79d   LoadBalancer   <pending>     80:32728/TCP
```

Gateway 도 `PROGRAMMED: False` 에서 진행되지 않았다.

```
NAME   CLASS   ADDRESS   PROGRAMMED   AGE
eg     eg                False        2m44s
```

### 진단 과정

GatewayClass 상태는 정상이었다.

```bash
kubectl get gatewayclass eg -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

```json
[{"message": "Valid GatewayClass", "reason": "Accepted", "status": "True"}]
```

`EnvoyProxy` 리소스도 생성되어 있었고 컨트롤러가 인식했다.

```bash
kubectl -n envoy-gateway-system get envoyproxy
# logssey-proxy   2m2s
```

**리소스 상태만으로는 원인을 알 수 없었다.** 컨트롤러 로그에서 확인했다.

```bash
kubectl -n envoy-gateway-system logs -l control-plane=envoy-gateway --tail=30 \
  | grep -iE "error|envoyproxy"
```

```
error  infrastructure  failed to create new infra
  {"error": "failed to create or update service envoy-gateway-system/envoy-envoy-gateway-system-eg-5391c79d:
   error during strategic merge: map: map[name:http-80 nodePort:30080]
   does not contain declared merge key: port"}
```

### 원인

Service 의 `ports` 배열은 StrategicMerge 에서 **`port` 를 병합 키로 사용**한다.
`name` 만 지정하면 어느 항목과 병합할지 결정할 수 없어 실패한다.

패치가 무시되는 것이 아니라 **인프라 생성 자체가 실패**한다.
그 결과 Service 가 갱신되지 않고 Gateway 도 Programmed 로 전환되지 않는다.

### 해결

`port` 를 함께 지정한다.

```yaml
ports:
  - port: 80
    name: http-80
    nodePort: 30080
```

적용 후 즉시 반영되었다.

```
NAME                                     TYPE       PORT(S)        AGE
envoy-envoy-gateway-system-eg-5391c79d   NodePort   80:30080/TCP   3m45s

NAME   CLASS   ADDRESS       PROGRAMMED   AGE
eg     eg      10.20.12.20   True         3m45s
```

### 포트 이름 확인 방법

패치의 `name` 은 Envoy Gateway 가 생성하는 Service 의 실제 포트 이름과
일치해야 한다. 리스너 이름(`http`)이 아니라 **`http-<port>`** 형식이다.

Gateway 를 먼저 만들고 Service 를 조회해 확인한다.

```bash
SVC=$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=eg \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n envoy-gateway-system get svc $SVC -o yaml | grep -A12 "ports:"
```

```yaml
ports:
- name: http-80
  nodePort: 32728
  port: 80
  protocol: TCP
  targetPort: 10080
```

`targetPort: 10080` 은 Envoy Gateway 가 특권 포트(<1024)를 비특권 포트로
내부 매핑한 결과다. 공식 문서에 명시된 동작이며 패치 대상이 아니다.

---

## 2차 — DoNotSchedule 롤링 교착

### 배경

Envoy Pod 가 1개뿐이어서 NLB 타겟 3대 중 1대만 healthy 였다.
`externalTrafficPolicy` 가 기본값 `Local` 이라 Pod 가 있는 노드만 응답한다.

replica 3 과 `externalTrafficPolicy: Cluster` 를 함께 적용했다.

```yaml
envoyDeployment:
  replicas: 3
  pod:
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: envoy
            gateway.envoyproxy.io/owning-gateway-name: eg
```

### 증상

Pod 3개는 정상 배치되었으나 4번째가 `Pending` 에서 진행되지 않았다.

```
NAME                              READY   STATUS    NODE
...-56f96ccb66-2kgks              0/2     Pending   <none>
...-7b8d448776-hfl4j              2/2     Running   worker-c
...-7b8d448776-ngw5t              2/2     Running   worker-d
...-7b8d448776-p9247              2/2     Running   worker-a
```

Deployment 는 `3/3` READY 이나 `UP-TO-DATE` 가 `1` 이었다.

```
NAME                                     READY   UP-TO-DATE   AVAILABLE
envoy-envoy-gateway-system-eg-5391c79d   3/3     1            3
```

ReplicaSet 을 보면 구버전이 3개를 유지한 채 신버전이 1개를 띄우려 하고 있었다.

```
NAME                  DESIRED   CURRENT   READY
...-56f96ccb66        1         1         0
...-7b8d448776        3         3         3
```

### 원인

Deployment 기본 전략은 `RollingUpdate` 이고 `maxSurge` 는 25% 다.
replica 3 이면 **4번째 Pod 를 먼저 띄운 뒤** 기존 Pod 를 내린다.

그런데 `whenUnsatisfiable: DoNotSchedule` 에 `maxSkew: 1` 이면
노드당 최대 1개만 허용된다. 워커가 3대이므로 4번째 Pod 가 배치될 자리가 없다.

```
새 Pod 스케줄 불가 → 기존 Pod 종료 안 됨 → 롤링 진행 불가
```

**replica 수와 노드 수가 같을 때 발생하는 교착**이다.

### 해결

제약을 `ScheduleAnyway` 로 완화한다.

```yaml
whenUnsatisfiable: ScheduleAnyway
```

`DoNotSchedule` 은 하드 제약이고 `ScheduleAnyway` 는 선호다.
자리가 없으면 한 노드에 2개를 허용하며, 롤링이 끝나면 다시 균등해진다.

적용 후 정상 완료되었다.

```
NAME                              READY   STATUS        NODE
...-57d68bd495-8v9f4              2/2     Running       worker-a
...-57d68bd495-dgjzm              2/2     Running       worker-d
...-57d68bd495-h9sjk              2/2     Running       worker-c
...-7b8d448776-hfl4j              2/2     Terminating   worker-c
```

### externalTrafficPolicy 효과 확인

롤링 업데이트가 진행되는 동안 NLB 타겟 3대가 계속 healthy 를 유지했다.

```
|  i-030605b5b05e1eb94 |  healthy  |
|  i-08aa421a354dcf78a |  healthy  |
|  i-0c18628fa30035aa9 |  healthy  |
```

`Local` 이었다면 Pod 가 교체되는 순간 해당 노드가 타겟에서 빠졌을 것이다.
`Cluster` 는 Pod 가 없는 노드도 다른 노드로 전달하므로 무중단이 유지된다.

---

## 재발 방지

- `k8s/platform/envoy-gateway/envoyproxy.yaml` 에 두 설정과 사유를 주석으로 기록
- `docs/07-ingress.md` 의 NodePort 고정 절에 반영

## 교훈

**컨트롤러가 관리하는 리소스는 상태만으로 원인을 알 수 없다.**

`GatewayClass` 는 Accepted, `EnvoyProxy` 는 생성됨, `kubectl apply` 도 성공했으나
실제로는 인프라 생성이 실패하고 있었다. 에러는 컨트롤러 로그에만 남는다.

Gateway API 리소스가 기대대로 동작하지 않으면 컨트롤러 로그를 먼저 본다.

```bash
kubectl -n envoy-gateway-system logs -l control-plane=envoy-gateway --tail=30 \
  | grep -iE "error"
```

**`DoNotSchedule` 은 replica 수와 토폴로지 도메인 수를 함께 고려해야 한다.**

두 값이 같으면 롤링 업데이트의 서지 Pod 가 배치될 자리가 없다.
`maxSurge: 0` 으로 두거나 `ScheduleAnyway` 를 쓴다.
metrics-server 와 Envoy Gateway 컨트롤플레인은 replica 2, 노드 3 이므로 여유가 있어 `DoNotSchedule` 로 두었다.

## 참고

| 항목 | 경로 |
| --- | --- |
| 매니페스트 | `k8s/platform/envoy-gateway/envoyproxy.yaml` |
| 설계 문서 | `docs/07-ingress.md` |
| 공식 문서 | Envoy Gateway — Customize EnvoyProxy |