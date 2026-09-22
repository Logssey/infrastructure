# Kubernetes 애드온

클러스터에 설치하는 플랫폼 컴포넌트의 Helm values 를 관리한다.

## 구조

```
k8s/
  platform/           클러스터 공통 컴포넌트
    metrics-server/
    aws-ebs-csi-driver/
```

애플리케이션 매니페스트는 별도 저장소에서 관리한다.

## 설치 목록

| 컴포넌트 | 차트 버전 | 앱 버전 | 네임스페이스 |
| --- | --- | --- | --- |
| metrics-server | 3.14.0 | 0.9.0 | kube-system |
| aws-ebs-csi-driver | 2.66.0 | 1.66.0 | kube-system |

## 설치 방법

Control Plane 1번 노드(cp-a)에서 실행한다.
현재는 values 파일을 노드에 직접 작성해 설치한다.
Argo CD 도입 후에는 이 디렉터리를 소스로 사용한다.

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update

helm install <name> <chart> --version <ver> -n <ns> -f values.yaml
```

**설치 전 렌더링 결과를 확인한다.**

```bash
helm template <name> <chart> --version <ver> -n <ns> -f values.yaml
```

차트마다 values 를 다루는 방식이 다르다. `defaultArgs` 와 `args` 가
합쳐지는지 덮어쓰는지, 지정한 키가 실제로 반영되는지 확인해야 한다.
차트가 지원하지 않는 키를 넣으면 조용히 무시된다.

---

## metrics-server

### 전제 조건 — kubelet serving certificate

metrics-server 는 kubelet 인증서가 클러스터 CA 로 서명되어 있어야 한다.
그렇지 않으면 `--kubelet-insecure-tls` 로 검증을 꺼야 하는데, 공식 문서는
이를 테스트 용도로만 권장한다.

Kubespray 인벤토리에 아래가 설정되어 있다.

```yaml
kubelet_rotate_server_certificates: true

kubelet_csr_approver_values:
  providerRegex: "^(cp|worker)-[acd]$"
  providerIpPrefixes:
    - "10.20.0.0/16"
  bypassDnsResolution: true
  maxExpirationSeconds: "86400"
```

`kubelet_rotate_server_certificates` 를 켜면 kubelet 이 클러스터 CA 에 CSR 을
요청하고, kubelet-csr-approver 가 자동 설치되어 승인을 처리한다.

approver 는 기본적으로 노드 DNS 이름 해석을 검증하나 본 환경의 노드명은
DNS 에 등록되어 있지 않다. DNS 검증을 끄는 대신 호스트명 정규식과
VPC IP 대역으로 승인 범위를 제한한다.

확인.

```bash
kubectl get csr
# 노드 6대 Approved,Issued

ansible -i <inventory> cp-a -m shell -b \
  -a "openssl x509 -in /var/lib/kubelet/pki/kubelet-server-current.pem \
      -noout -issuer -ext subjectAltName"
# issuer=CN = kubernetes
# DNS:cp-a, IP Address:10.20.10.10
```

상세는 `kubespray/README.md` 참조.

### 전제 조건 — Security Group

kubelet API(10250) 경로가 열려 있어야 한다.

| 출발지 | 목적지 | 용도 |
| --- | --- | --- |
| sg-control-plane | sg-worker | apiserver → Worker Pod |
| sg-control-plane | sg-control-plane | apiserver → CP Pod |
| sg-worker | sg-control-plane | metrics-server → CP kubelet |
| sg-worker | sg-worker | metrics-server → Worker kubelet |

컴포넌트를 추가하기 전에 필요한 통신 경로를 먼저 검토한다.
상세는 `docs/02-security.md` 와 `docs/troubleshooting/06-kubelet-api-sg.md` 참조.

### 검증

```bash
kubectl top nodes
```

노드 6대 전부 값이 나와야 한다. `<unknown>` 이 있으면 해당 노드의
kubelet 접근 경로를 확인한다.

```bash
kubectl -n kube-system logs -l app.kubernetes.io/name=metrics-server \
  --since=1m | grep "Failed to scrape"

kubectl get apiservice v1beta1.metrics.k8s.io
# AVAILABLE True
```

---

## aws-ebs-csi-driver

PVC 로 EBS 볼륨을 동적 프로비저닝한다. `gp3` StorageClass 를 기본으로 생성한다.

### 전제 조건 — IAM

노드 IAM Role 에 `AmazonEBSCSIDriverPolicy` 가 부착되어 있다.
`terraform/modules/iam/main.tf` 의 공통 정책 영역에 정의되어 있으며,
`security_mode` 와 무관하게 유지된다.

`permissive` 모드의 `AmazonEC2FullAccess` 로도 동작하지만,
`strict` 전환 시 해당 정책이 제거되면 볼륨 프로비저닝이 중단된다.

self-managed 클러스터에는 IRSA 가 없으므로 드라이버가 IMDS 를 통해
노드 Role 의 자격증명을 사용한다. 노드 위의 모든 Pod 가 같은 권한을
갖게 되는 구조적 한계가 있다.

**T2 후보.** AWS 가 `AmazonEBSCSIDriverPolicyV2` 를 제공한다.
드라이버용으로 태그된 볼륨과 스냅샷으로 범위를 좁힌 정책이다.
마이그레이션 가이드는 차트 설치 노트 참조.

### StorageClass

```yaml
name: gp3
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
  csi.storage.k8s.io/fstype: ext4
```

**`WaitForFirstConsumer` 가 중요하다.**
`Immediate` 로 두면 PVC 생성 즉시 임의 AZ 에 볼륨이 만들어지고,
Pod 가 다른 AZ 에 스케줄되면 연결할 수 없다. EBS 는 AZ 를 넘지 못한다.
본 환경은 노드가 3개 AZ 에 분산되어 있어 실제로 발생하는 문제다.

`encrypted` 는 볼륨 생성 후 변경할 수 없다.

`iops` 와 `throughput` 은 지정하지 않는다. gp3 기본값(3000 IOPS, 125 MB/s)이
적용되며, 다른 값이 필요하면 별도 StorageClass 를 추가한다.

### 검증

PVC 와 Pod 를 함께 생성해야 한다. PVC 만 만들면 `WaitForFirstConsumer`
때문에 `Pending` 에 머문다. 이것이 정상 동작이다.

```bash
cat > /tmp/test-pvc.yaml << 'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ebs-test
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: ebs-test
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "echo hello > /data/test.txt && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ebs-test
YAML

kubectl apply -f /tmp/test-pvc.yaml
```

```bash
kubectl get pvc,pv
kubectl exec ebs-test -- cat /data/test.txt
kubectl exec ebs-test -- df -h /data
```

AWS 에서 볼륨 속성을 확인한다.

```bash
aws ec2 describe-volumes \
  --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=ebs-test" \
  --region ap-northeast-1 \
  --query 'Volumes[].[VolumeId,VolumeType,Size,Encrypted,AvailabilityZone,State]' \
  --output table
```

| 확인 | 기대 |
| --- | --- |
| VolumeType | gp3 |
| Encrypted | True |
| AvailabilityZone | Pod 가 스케줄된 노드의 AZ 와 일치 |

정리. `reclaimPolicy: Delete` 이므로 EBS 볼륨도 함께 삭제된다.

```bash
kubectl delete -f /tmp/test-pvc.yaml
```

PV 가 `Released` 를 거쳐 사라지는 데 30초 정도 걸린다.
AWS 에서 볼륨이 남아 있지 않은지 확인한다. 남으면 비용이 계속 발생한다.

---

## 보류

| 컴포넌트 | 사유 |
| --- | --- |
| cert-manager | 용도가 불명확하다. 외부 TLS 는 CloudFront 와 ACM 이 담당하므로 클러스터 내부에서 인증서가 필요한 시점에 재검토한다. |