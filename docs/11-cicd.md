# 11. CI/CD

## 참고 문서

| 항목 | 링크 |
| --- | --- |
| Argo CD Best Practices | https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/ |
| Argo CD Automated Sync | https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/ |
| Argo CD Sync Phases and Waves | https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/ |
| Argo CD Cluster Bootstrapping | https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/ |
| GitHub Actions OIDC (AWS) | https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services |
| ECR 수명주기 정책 | https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html |
| External Secrets Operator | https://external-secrets.io/latest/ |

---

## 전체 흐름

```
reused-backend                     reused-frontend
      │ push (main)                       │ push (main)
      ▼                                   ▼
GitHub Actions                      GitHub Actions
  빌드 → ECR 푸시                     빌드 → ECR 푸시
      │                                   │
      └─────────────┬─────────────────────┘
                    │ 이미지 태그 갱신 커밋
                    ▼
              gitops 레포
                    │
                    ▼ 폴링 또는 웹훅
               Argo CD
                    │
                    ▼
                클러스터
```

**CI 와 CD 의 책임이 나뉜다.**

| 단계 | 하는 일 | 주체 |
| --- | --- | --- |
| CI | 빌드, 테스트, 이미지 푸시 | 앱 레포의 GitHub Actions |
| 태그 갱신 | gitops 레포의 이미지 태그 수정 | 앱 레포의 GitHub Actions |
| CD | 클러스터를 Git 상태와 일치시킴 | Argo CD |

**Argo CD 는 앱 레포를 알지 못한다.**
gitops 레포만 보고 동작하며, 이미지가 어떻게 만들어졌는지는 관여하지 않는다.

---

## 레포 구조

네 개로 나눈다.

| 레포 | 내용 | 공개 |
| --- | --- | --- |
| `reused-backend` | Spring Boot 소스, CI 워크플로 | — |
| `reused-frontend` | 프론트엔드 소스, CI 워크플로 | — |
| `infrastructure` | Terraform, Kubespray, 클러스터 애드온, 문서 | — |
| `gitops` | Helm 차트, Argo CD Application | Private |

### 왜 gitops 레포를 분리하는가

Argo CD 공식 문서가 제시하는 근거는 다섯 가지다.

| # | 근거 | 우리 상황 |
| --- | --- | --- |
| 1 | 애플리케이션 코드와 설정의 분리 | 해당 |
| 2 | 깔끔한 감사 로그 | 해당 |
| 3 | **여러 레포에서 빌드된 서비스가 하나로 배포된다** | **직접 해당** |
| 4 | 접근 분리 | 부분 해당 |
| 5 | CI 무한 루프 방지 | 해당 없음 |

**3번이 결정적이었다.**

> 애플리케이션이 여러 Git 레포에서 빌드된 서비스들로 구성되지만
> 하나의 단위로 배포될 수 있다.
> 그 매니페스트를 한 컴포넌트의 소스 레포에 두는 것은 말이 되지 않는다.

백엔드와 프론트엔드가 별도 레포이므로 매니페스트를 어느 한쪽에 둘 수 없다.
`infrastructure` 에 두는 것도 같은 이유로 맞지 않는다.
인프라 레포는 애플리케이션 배포 단위가 아니다.

**5번은 해당하지 않는다.**
CI 는 앱 레포에서 돌고 매니페스트는 별도 레포에 있으므로
태그를 갱신해도 CI 가 다시 트리거되지 않는다.

### 애드온을 어디에 두는가

기준은 **"Argo CD 없이도 있어야 하는가"** 다.

| 컴포넌트 | Argo CD 없이 필요? | 위치 |
| --- | --- | --- |
| Cilium | 필수. 없으면 Pod 통신 불가 | `infrastructure` |
| EBS CSI Driver | 필수. PVC 사용 불가 | `infrastructure` |
| Envoy Gateway | 필수. 외부 진입 경로 | `infrastructure` |
| Argo CD | 자기 자신을 관리할 수 없다 | `infrastructure` |
| ESO 오퍼레이터 | CRD 가 먼저 등록되어야 한다 | `infrastructure` |
| **ExternalSecret** | 애플리케이션과 함께 변한다 | **`gitops`** |
| Prometheus, Grafana, Loki | 없어도 클러스터는 동작 | `gitops` |
| 애플리케이션 | 없어도 클러스터는 동작 | `gitops` |

### 문서는 각 레포에

| 대상 | 위치 |
| --- | --- |
| 인프라 명세, 개념, 트러블슈팅 | `infrastructure/docs/` |
| CI/CD 전체 흐름 | `infrastructure/docs/11-cicd.md` (이 문서) |
| gitops 레포 구조, Argo CD 운영 | `gitops/README.md` |
| 앱 빌드·실행 | 각 앱 레포 README |

**코드와 문서가 멀어지면 문서가 낡는다.**
같은 PR 에 코드와 문서가 들어가야 리뷰에서 확인된다.

여러 레포에 걸친 내용은 한 곳에 쓰고 나머지에서 링크한다.

---

## ECR

### 리포지토리 구성

서비스별로 나눈다.

```
logssey/reused-api
logssey/reused-web
```

**리포지토리 개수 자체는 과금되지 않는다.**
저장 용량(GB/월)과 데이터 전송량으로만 계산되므로
나누는 것이 비용 면에서 불리하지 않다.

나누면 얻는 것이 있다.

| 이점 | 내용 |
| --- | --- |
| 이미지 스캔 | 리포지토리 단위로 결과 확인 |
| 수명주기 정책 | 서비스마다 다르게 적용 |
| IAM 권한 | 리포지토리별 제어 |

### 수명주기 정책

이미지가 쌓이면 저장 비용이 늘어난다.

| 우선순위 | 규칙 | 값 |
| --- | --- | --- |
| 1 | 태그 없는 이미지 삭제 | push 후 1일 |
| 2 | 개수 제한 | 최근 20개 유지 |

**20개로 잡은 이유는 롤백 여지 때문이다.**
Argo CD 에서 이전 커밋으로 되돌릴 때 해당 이미지가 남아 있어야 한다.

태그 없는 이미지는 새 이미지가 같은 태그를 덮어쓸 때 생긴다.
쓸모가 없으므로 빠르게 정리한다.

### 이미지 태그 전략

**커밋 SHA 를 기본 태그로 쓴다.**

```
logssey/reused-api:a3f2c1d              배포가 참조하는 태그
logssey/reused-api:main                 브랜치 최신 (개발 확인용)
```

`latest` 나 브랜치 태그를 배포에 쓰지 않는다.
**같은 태그가 다른 이미지를 가리킬 수 있어 GitOps 원칙이 깨진다.**

"Git 에 적힌 것 = 클러스터에서 도는 것" 이 보장되려면
태그가 불변이어야 한다.

### 추적성은 라벨로 보완한다

SHA 만으로는 사람이 읽기 어렵다.
OCI 표준 라벨을 이미지에 심는다.

```dockerfile
LABEL org.opencontainers.image.revision=$GIT_SHA
LABEL org.opencontainers.image.version=$VERSION
LABEL org.opencontainers.image.created=$BUILD_DATE
LABEL org.opencontainers.image.source=https://github.com/Logssey/reused-backend
```

```bash
docker inspect <image> --format '{{json .Config.Labels}}'
```

취약점 스캐너도 이 라벨을 읽어 출처를 표시한다.

---

## GitHub Actions

### OIDC — 액세스 키를 쓰지 않는다

GitHub Actions 가 AWS 에 접근할 때 **장기 자격증명을 저장하지 않는다.**

```
GitHub Actions 실행
  → GitHub 가 OIDC 토큰 발급
  → AWS STS 에 AssumeRoleWithWebIdentity
  → 임시 자격증명 (기본 1시간)
```

| 방식 | 문제 |
| --- | --- |
| IAM User 액세스 키 | 유출 시 무기한 유효. 로테이션 필요 |
| **OIDC** | 실행마다 임시 발급. 저장할 것이 없다 |


### 신뢰 정책

**특정 레포와 브랜치만 assume 할 수 있게 제한한다.**

```hcl
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values   = [
    "repo:Logssey/reused-backend:ref:refs/heads/main",
    "repo:Logssey/reused-frontend:ref:refs/heads/main",
  ]
}
```

조건을 빠뜨리면 **누구의 GitHub Actions 든 이 Role 을 쓸 수 있다.**
`sub` 클레임 검증이 없으면 다른 조직의 워크플로도 통과한다.

### 워크플로 구조

```yaml
permissions:
  id-token: write      # OIDC 토큰 발급에 필요
  contents: read

steps:
  - uses: actions/checkout@v4

  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
      aws-region: ap-northeast-1

  - uses: aws-actions/amazon-ecr-login@v2

  - name: Build and push
    run: |
      docker build -t $ECR_REGISTRY/$REPO:$GITHUB_SHA .
      docker push $ECR_REGISTRY/$REPO:$GITHUB_SHA
```

`permissions.id-token: write` 가 없으면 OIDC 토큰이 발급되지 않는다.
기본값이 아니므로 명시해야 한다.

### gitops 레포 갱신

CI 가 마지막에 gitops 레포의 이미지 태그를 바꾼다.

```yaml
  - name: Update gitops repo
    run: |
      git clone https://x-access-token:${TOKEN}@github.com/Logssey/gitops.git
      cd gitops
      yq -i '.image.tag = "${{ github.sha }}"' apps/reused-api/values.yaml
      git commit -am "chore: bump reused-api to ${{ github.sha }}"
      git push
```

**인증은 GitHub App 을 쓴다.**

| 방식 | 문제 |
| --- | --- |
| Personal Access Token | 개인 계정에 종속. |
| Deploy Key | 레포별 SSH 키. 관리 대상이 늘어난다 |
| **GitHub App** | 설치 범위가 명확. 토큰이 자동 만료된다 |

### Argo CD Image Updater 를 쓰지 않는 이유

ECR 을 폴링해 새 태그를 자동 감지하는 컴포넌트가 있다.
CI 에 gitops 레포 쓰기 권한이 필요 없어진다는 이점이 있다.

다만 **배포 이력이 Git 에 남지 않는다.**
누가 언제 무엇을 배포했는지가 커밋으로 드러나는 것이
GitOps 를 쓰는 이유 중 하나다.

권한 문제는 GitHub App 으로 범위를 좁혀 해결한다.

---

## gitops 레포

### 디렉터리 구조

```
gitops/
  apps/
    reused-api/
      Chart.yaml
      values.yaml
      templates/
    reused-web/
  platform/
    kube-prometheus-stack/
    loki/
  argocd/
    projects/
    applications/
  README.md
```

| 디렉터리 | 내용 |
| --- | --- |
| `apps/` | 애플리케이션 Helm 차트 |
| `platform/` | 관측성 등 플랫폼 컴포넌트 |
| `argocd/` | Argo CD Application, AppProject 정의 |

**Kubernetes 리소스와 Argo CD 리소스를 섞지 않는다.**
성격과 변경 주체가 다르기 때문이다.

### Helm 차트를 여기에 두는 이유

차트 전체를 gitops 레포에 둔다.
앱 레포에 차트를 두고 values 만 gitops 에 두는 방식도 있으나,
**백엔드와 프론트엔드 중 어디에 둘지 정할 수 없다.**

레포 분리의 3번 근거와 같은 이유다.

### 환경 구분

**브랜치로 환경을 나누지 않는다.**

환경 간 병합이 발생하면 환경별로 달라야 할 값까지 섞인다.
Argo CD 관련 가이드가 공통으로 지적하는 안티패턴이다.

values 파일로 나눈다.

```
values.yaml              공통 기본값
values-prod.yaml         prod override
values-staging.yaml      staging override (필요 시)
```

현재는 prod 하나뿐이므로 `values.yaml` 만 둔다.

---

## Argo CD

### 설치 위치

`infrastructure` 에서 Helm 으로 설치한다.

**Argo CD 는 자기 자신을 관리할 수 없다.**
클러스터를 재구축할 때 Argo CD 가 없는 상태에서 시작하므로
부트스트랩은 수동이어야 한다.

```
클러스터 생성 → CNI → CSI → Ingress → Argo CD 설치 → root Application 적용
                                                          ↓
                                                    이후 GitOps
```

앞의 두 단계까지가 수동이고, 그 다음부터 선언형이다.

### 동기화 정책

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

| 옵션 | 설정 | 이유 |
| --- | --- | --- |
| `automated` | 활성 | Git 변경을 자동 반영 |
| `selfHeal` | true | 클러스터 직접 변경을 Git 상태로 되돌린다 |
| `prune` | true | Git 에서 삭제된 리소스를 클러스터에서도 제거 |

**`selfHeal` 이 GitOps 의 핵심이다.**
누가 `kubectl edit` 으로 바꿔도 Git 상태로 복원된다.
"Git 이 유일한 진실" 이 실제로 성립하게 만든다.

**`prune` 은 위험을 동반한다.**
파일을 실수로 지우면 운영 리소스가 삭제된다.

보호가 필요한 리소스에는 어노테이션을 붙인다.

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
```

PVC 처럼 데이터를 담은 리소스에 적용한다.

### App of Apps

Argo CD Application 을 하나하나 손으로 적용하면
GitOps 범위 밖의 수동 작업이 늘어난다.

**root Application 하나만 적용하고, 그것이 나머지를 만들게 한다.**

```
root Application  (수동 적용, 한 번)
  → gitops/argocd/applications/ 를 감시
      → reused-api Application
      → reused-web Application
      → kube-prometheus-stack Application
```

Argo CD 공식 문서의 Cluster Bootstrapping 패턴이다.

### 접근 방법

초기에는 포트포워딩으로 접근한다.

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

**외부 노출은 인증 설정을 전제로 한다.**
와일드카드 인증서가 있어 `argocd.re-used.store` 로 노출할 수 있으나,
기본 admin 계정을 공개하는 것은 위험하다.

노출할 경우 GitHub OAuth 연동이 필요하다. 확장 항목으로 둔다.

---

## Secret 관리

### External Secrets Operator

AWS Secrets Manager 의 값을 Kubernetes Secret 으로 동기화한다.

```
AWS Secrets Manager
      ↓ ESO 가 주기적으로 조회
Kubernetes Secret
      ↓
   Pod 가 참조
```

**Git 에는 참조만 남는다.** 값은 들어가지 않는다.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: reused-api-secrets
spec:
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: reused-api-secrets
  data:
    - secretKey: db-password
      remoteRef:
        key: rds!db-xxxxx
        property: password
```

### 왜 ESO 인가

**이미 AWS Secrets Manager 와 SSM Parameter Store 를 쓰고 있다.**
RDS 마스터 비밀번호는 Secrets Manager 에,
Redis ACL 비밀번호는 Parameter Store 에 있다.

| 방식 | 언제 쓰나 | 판단 |
| --- | --- | --- |
| **ESO** | 외부 시크릿 저장소가 이미 있을 때 | **채택** |
| Sealed Secrets | 외부 저장소 없이 Git 에 암호화해 넣을 때 | 미채택 |
| HashiCorp Vault | 멀티클라우드, 동적 시크릿, 대규모 조직 | 미채택 |

**Vault 는 규모에 비해 과하다.**
HA 구성에 노드 3~5대가 필요하고 unseal, 업그레이드, 백업 부담이 따른다.

**Sealed Secrets 는 맞지 않는다.**
외부 저장소가 없을 때의 선택인데 우리는 이미 있다.
클러스터별 sealing 키를 백업·로테이션해야 하는 부담도 있다.

### 설치를 둘로 나눈다

| 대상 | 위치 | 이유 |
| --- | --- | --- |
| ESO 오퍼레이터 | `infrastructure` | CRD 가 먼저 등록되어야 한다 |
| ClusterSecretStore | `infrastructure` | 클러스터 단위 설정 |
| **ExternalSecret** | **`gitops`** | 애플리케이션과 함께 변한다 |

**순서 문제를 피하면서 GitOps 이점을 얻는 구성이다.**

전부 Argo CD 로 관리하면 CRD 등록 전에 CR 을 적용하려다 실패할 수 있다.
sync wave 로 해결할 수 있으나 디버깅이 복잡해진다.

반대로 전부 `infrastructure` 에 두면
애플리케이션 시크릿을 추가할 때마다 `helm upgrade` 를 수동 실행해야 한다.

### IAM 권한

ESO 가 Secrets Manager 를 읽으려면 권한이 필요하다.

현재 노드 IAM Role 에는 `AmazonSSMManagedInstanceCore` 만 있다.
Secrets Manager 읽기 권한을 추가한다.

```hcl
Action = [
  "secretsmanager:GetSecretValue",
  "secretsmanager:DescribeSecret",
]
```

**한계** — IRSA 가 없으므로 노드 Role 을 쓴다.
그 노드의 모든 Pod 가 같은 권한을 갖게 된다.

IRSA 를 쓰면 ServiceAccount 단위로 권한을 줄 수 있으나,
자체 관리 클러스터에서는 OIDC provider 를 직접 구성해야 한다.
확장 항목으로 둔다. `docs/03-iam.md` 참조.

---

## 공식 권장 사항

Argo CD 문서가 제시하는 두 가지를 따른다.

### replicas 를 Git 에 넣지 않는다

HPA 로 replica 수를 관리할 경우에 해당한다.

```yaml
spec:
  # replicas: 1        HPA 를 쓸 경우 제외
  template:
    ...
```

**Git 에 두면 Argo CD 가 Git 값으로 되돌리고 HPA 가 다시 바꾸는 싸움이 난다.**

### 외부 의존성의 버전을 고정한다

Helm 차트나 Kustomize base 를 외부에서 가져올 때,
버전을 고정하지 않으면 **같은 Git 리비전이 다른 매니페스트를 만들어낸다.**

```yaml
# 나쁨
dependencies:
  - name: postgresql
    version: "^13.0.0"

# 좋음
dependencies:
  - name: postgresql
    version: "13.2.24"
```

---

## 확인

### ECR

```bash
aws ecr describe-repositories \
  --region ap-northeast-1 \
  --query 'repositories[].[repositoryName,repositoryUri]' \
  --output table
```

수명주기 정책 확인.

```bash
aws ecr get-lifecycle-policy \
  --repository-name logssey/reused-api \
  --region ap-northeast-1 \
  --query 'lifecyclePolicyText' --output text | python3 -m json.tool
```

### OIDC Provider

```bash
aws iam list-open-id-connect-providers
```

```bash
aws iam get-role \
  --role-name logssey-prod-role-github-actions \
  --query 'Role.AssumeRolePolicyDocument' \
  --output json
```

`sub` 조건에 레포와 브랜치가 명시되어 있어야 한다.

### CI 동작

워크플로 실행 후 이미지가 올라왔는지 확인한다.

```bash
aws ecr list-images \
  --repository-name logssey/reused-api \
  --region ap-northeast-1 \
  --query 'imageIds[].imageTag' \
  --output table
```

### Argo CD

```bash
kubectl -n argocd get applications
```

```bash
kubectl -n argocd get application reused-api \
  -o jsonpath='{.status.sync.status} {.status.health.status}'
```

`Synced Healthy` 여야 한다.

### ExternalSecret

```bash
kubectl get externalsecret -A
kubectl get secret reused-api-secrets -o jsonpath='{.data}' | python3 -m json.tool
```

동기화 상태 확인.

```bash
kubectl get externalsecret reused-api-secrets \
  -o jsonpath='{.status.conditions[0]}' | python3 -m json.tool
```

`type: Ready`, `status: "True"` 여야 한다.

---

## 확장 항목

| 항목 | 시점 |
| --- | --- |
| Trivy 이미지 스캔 | 보안 스캔 단계. Prowler, Gitleaks 와 함께 |
| Gitleaks | 같음. 커밋 전 시크릿 검출 |
| Argo CD 외부 노출 + GitHub OAuth | 팀이 늘거나 원격 접근이 필요할 때 |
| IRSA | Pod 단위 IAM 권한이 필요할 때 |
| Argo Rollouts | 카나리·블루그린 배포가 필요할 때 |
| Argo CD Notifications | 배포 결과를 Slack 등으로 알릴 때 |
| 웹훅 | 폴링 지연을 줄일 때. 기본 3분 |
| staging 환경 | 검증 단계가 필요할 때 |