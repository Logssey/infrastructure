# 11. CI/CD

## 참고 문서

| 항목 | 링크 |
| --- | --- |
| Argo CD Best Practices | https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/ |
| Argo CD Automated Sync | https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/ |
| Argo CD ApplicationSet | https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/ |
| Argo CD Cluster Bootstrapping | https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/ |
| GitHub Actions OIDC (AWS) | https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services |
| ECR 수명주기 정책 | https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html |
| External Secrets Operator | https://external-secrets.io/latest/ |
| kubelet 자격증명 공급자 | https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/ |

---

## 전체 흐름

```
service-backend                    service-frontend
  (api · chat)                          (web)
      │ PR 생성·커밋                        │ PR 생성·커밋
      ▼                                   ▼
GitHub Actions                      GitHub Actions
  빌드 → ECR  pr-{SHA}                빌드 → ECR  pr-{SHA}
      │                                   │
      │ 머지                               │ 머지
      ▼                                   ▼
  {SHA} 로 리태깅                       {SHA} 로 리태깅
      │                                   │
      └─────────────┬─────────────────────┘
                    │ values.yaml 태그 갱신 커밋
                    ▼
              gitops 레포
                    │
                    ▼ 폴링 (기본 3분)
               Argo CD
                    │
                    ▼
                클러스터
```

**CI 와 CD 의 책임이 나뉜다.**

| 단계 | 하는 일 | 주체 |
| --- | --- | --- |
| CI | 빌드, 이미지 푸시 | 앱 레포의 GitHub Actions |
| 태그 갱신 | gitops 레포의 이미지 태그 수정 | 앱 레포의 GitHub Actions |
| CD | 클러스터를 Git 상태와 일치시킴 | Argo CD |

**Argo CD 는 앱 레포를 알지 못한다.**
gitops 레포만 보고 동작하며, 이미지가 어떻게 만들어졌는지는 관여하지 않는다.

**Push 가 아니라 Pull 이다.** CI 가 클러스터에 명령을 보내지 않는다.
덕분에 CI 에 클러스터 자격증명을 두지 않아도 된다.

---

## 레포 구조

네 개로 나눈다.

| 레포 | 내용 | 공개 |
| --- | --- | --- |
| `service-backend` | Spring Boot 소스, `chat-server/` 하위에 Node 채팅 게이트웨이 | Private |
| `service-frontend` | Vite + React 소스 | Private |
| `infrastructure` | Terraform, Kubespray, 클러스터 애드온, 문서 | Private |
| `gitops` | Helm 차트, Argo CD 리소스 | Private |

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

### 채팅 게이트웨이를 백엔드 레포에 둔 이유

채팅 게이트웨이는 Node.js 로 별도 프로세스이지만
**Spring API 와 계약이 강하게 묶여 있다.**

| 항목 | 내용 |
| --- | --- |
| 인증 | `GET /api/v1/chat/session` 호출 |
| 권한 확인 | `GET /api/v1/chat-rooms/{id}/subscription` 호출 |
| 이벤트 형식 | Spring 이 발행하는 envelope 구조에 의존 |

API 계약이 바뀌면 둘을 함께 고쳐야 한다.
레포를 나누면 그때마다 두 PR 을 맞춰야 하므로 한 레포에 두었다.

빌드는 나눈다. 아래 paths-filter 절 참조.

### 애드온을 어디에 두는가

기준은 **"Argo CD 없이도 있어야 하는가"** 다.

| 컴포넌트 | Argo CD 없이 필요? | 위치 |
| --- | --- | --- |
| Cilium | 필수. 없으면 Pod 통신 불가 | `infrastructure` |
| EBS CSI Driver | 필수. PVC 사용 불가 | `infrastructure` |
| Envoy Gateway | 필수. 외부 진입 경로 | `infrastructure` |
| Argo CD | 자기 자신을 관리할 수 없다 | `infrastructure` |
| ESO 오퍼레이터 | CRD 가 먼저 등록되어야 한다 | `infrastructure` |
| ClusterSecretStore | 클러스터 단위 설정 | `infrastructure` |
| ECR credential provider | kubelet 설정. 클러스터 밖 | 노드 user_data |
| **ExternalSecret** | 애플리케이션과 함께 변한다 | **`gitops`** |
| 애플리케이션 | 없어도 클러스터는 동작 | `gitops` |
| Prometheus, Grafana, Loki | 같음 | `gitops` (예정) |

### 문서는 각 레포에

| 대상 | 위치 |
| --- | --- |
| 인프라 명세, 개념, 트러블슈팅 | `infrastructure/docs/` |
| CI/CD 전체 흐름 | `infrastructure/docs/11-cicd.md` (이 문서) |
| gitops 레포 구조, Argo CD 운영 | `gitops/README.md` |
| 앱 빌드·실행 | 각 앱 레포 README |

**코드와 문서가 멀어지면 문서가 낡는다.**
같은 PR 에 코드와 문서가 들어가야 리뷰에서 확인된다.

---

## ECR

### 리포지토리 구성

서비스별로 나눈다.

```
logssey/reused-api
logssey/reused-chat
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

| 우선순위 | 규칙 | 값 |
| --- | --- | --- |
| 1 | 태그 없는 이미지 삭제 | push 후 1일 |
| 2 | 개수 제한 | 최근 20개 유지 |

**20개로 잡은 이유는 롤백 여지 때문이다.**
Argo CD 에서 이전 커밋으로 되돌릴 때 해당 이미지가 남아 있어야 한다.

`pr-{SHA}` 태그도 이 개수에 포함된다. PR 을 자주 올리면 한도가 빨리 찬다.
서비스별로 리포지토리를 나눈 것이 여기서도 도움이 된다.

### 이미지 태그 전략

**태그를 두 단계로 나눈다.**

| 시점 | 태그 | 의미 |
| --- | --- | --- |
| PR 생성·커밋 추가 | `pr-{SHA}` | 검증용. 배포 대상 아님 |
| 머지 | `{SHA}` | 배포 대상 |

빌드는 PR 단계에서 한 번만 한다.
머지 시에는 **재빌드하지 않고 매니페스트만 복사해 태그를 추가한다.**

```bash
MANIFEST=$(aws ecr batch-get-image \
  --repository-name "$ECR_REPOSITORY" \
  --image-ids imageTag="pr-$SHA" \
  --query 'images[].imageManifest' --output text)

aws ecr put-image \
  --repository-name "$ECR_REPOSITORY" \
  --image-tag "$SHA" \
  --image-manifest "$MANIFEST"
```

**재빌드하면 다른 이미지가 된다.** 빌드 시각, 의존성 해석 결과,
베이스 이미지 갱신 등으로 내용이 달라질 수 있다.
그러면 PR 에서 검증한 것과 배포되는 것이 같다는 보장이 깨진다.

`latest` 나 브랜치 태그는 배포에 쓰지 않는다.
같은 태그가 다른 이미지를 가리킬 수 있어 GitOps 원칙이 깨진다.

### 추적성은 라벨로 보완한다

SHA 만으로는 사람이 읽기 어렵다. OCI 표준 라벨을 빌드 시점에 심는다.

```bash
docker build \
  --label "org.opencontainers.image.revision=${SHA}" \
  --label "org.opencontainers.image.source=${SERVER_URL}/${REPOSITORY}" \
  --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t "$REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" .
```

```bash
docker inspect <image> --format '{{json .Config.Labels}}'
```

취약점 스캐너도 이 라벨을 읽어 출처를 표시한다.

### kubelet 이 ECR 에서 이미지를 받으려면

**Kubernetes 1.27 에서 in-tree ECR 자격증명 공급자가 제거되었다.**
노드 IAM Role 에 권한이 있어도 kubelet 이 그것을 ECR 토큰으로 바꾸지 못한다.

Worker 3대에 `ecr-credential-provider` 를 설치하고 kubelet 플래그를 추가해야 한다.
구축 과정과 함정은 `docs/troubleshooting/09-ecr-credential-provider.md` 참조.

---

## GitHub Actions

### OIDC — 액세스 키를 쓰지 않는다

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

### 신뢰 정책 — sub 클레임에 ID 가 붙는다

**특정 레포와 브랜치만 assume 할 수 있게 제한한다.**

조건을 빠뜨리면 누구의 GitHub Actions 든 이 Role 을 쓸 수 있다.

그런데 **2026-07-15 이후 생성된 레포는 `sub` 클레임 형식이 다르다.**
조직 ID 와 레포 ID 가 접미사로 붙는다.

```
repo:Logssey@329835088/service-backend@1372604005:pull_request
```

기존 형식으로 조건을 쓰면 매칭되지 않는다.

```hcl
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values = [
    "repo:Logssey@*/service-backend@*:ref:refs/heads/main",
    "repo:Logssey@*/service-frontend@*:ref:refs/heads/main",
    "repo:Logssey@*/service-backend@*:pull_request",
    "repo:Logssey@*/service-frontend@*:pull_request",
  ]
}
```

`StringEquals` 가 아니라 `StringLike` 를 쓰고 와일드카드로 ID 부분을 덮는다.

**`pull_request` 항목이 별도로 필요하다.**
`on: pull_request` 로 트리거된 워크플로의 `sub` 는
`ref:refs/heads/main` 이 아니라 `:pull_request` 로 끝난다.
브랜치 조건만 두면 PR 빌드가 인증에 실패한다.

### 워크플로 구조

```yaml
on:
  pull_request:
    types: [opened, synchronize, closed]
    branches: [main]

permissions:
  id-token: write        # OIDC 토큰 발급
  contents: read
  pull-requests: read    # paths-filter 가 변경 파일 조회

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

`permissions.id-token: write` 가 없으면 OIDC 토큰이 발급되지 않는다.
기본값이 아니므로 명시해야 한다.

job 은 넷이다.

| job | 조건 | 하는 일 |
| --- | --- | --- |
| `changes` | 항상 | 변경 경로 판별 |
| `build-*` | opened·synchronize | 빌드 후 `pr-{SHA}` push |
| `retag` | merged | `{SHA}` 로 리태깅 |
| `deploy` | merged | gitops 태그 갱신 |

**빌드를 PR 단계에서 하는 이유**는 머지 후에 빌드 실패를 알면 곤란하기 때문이다.

### 한 레포의 두 서비스를 나눠 빌드한다

`service-backend` 에는 API 와 채팅 게이트웨이가 함께 있다.
둘 다 빌드하면 시간이 두 배가 되고 ECR 수명주기 한도도 빨리 찬다.

`dorny/paths-filter` 로 바뀐 쪽만 빌드한다.

```yaml
  changes:
    runs-on: ubuntu-latest
    outputs:
      api: ${{ steps.filter.outputs.api }}
      chat: ${{ steps.filter.outputs.chat }}
    steps:
      - uses: actions/checkout@v7
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            api:
              - 'src/**'
              - 'build.gradle'
              - 'settings.gradle'
              - 'gradle/**'
              - 'gradlew'
              - 'gradlew.bat'
              - 'Dockerfile'
              - '.dockerignore'
              - 'schema/**'
              - '.github/workflows/**'
            chat:
              - 'chat-server/**'
              - '.github/workflows/**'
```

**`.github/workflows/**` 가 양쪽에 들어간다.**
워크플로 자체가 바뀌면 두 빌드가 모두 제대로 도는지 확인해야 한다.

`schema/**` 를 api 에 넣은 것은 스키마 변경이 배포와 함께 검토되도록
의식시키기 위함이다. 스키마 파일은 이미지에 들어가지 않는다.

**`pull-requests: read` 권한이 없으면 실패한다.**

```
Error: Resource not accessible by integration
```

paths-filter 가 PR 의 변경 파일 목록을 GitHub API 로 조회하기 때문이다.

### 빌드 방식이 서비스마다 다르다

| 서비스 | 빌드 위치 | 이유 |
| --- | --- | --- |
| api | 러너에서 Gradle | 멀티스테이지 없이 JAR 만 복사 |
| chat | 컨테이너 안 | Dockerfile 이 멀티스테이지 |
| web | 러너에서 Vite | `dist/` 를 nginx 이미지에 복사 |

api 는 테스트를 건너뛴다.

```yaml
      - name: Build
        run: ./gradlew build -x test
```

Testcontainers 가 PostgreSQL·Redis 컨테이너를 띄워 시간이 오래 걸린다.
로컬에서 `./gradlew test` 로 검증한 뒤 PR 을 올리는 것을 전제로 한다.

web 은 테스트를 포함한다. Vitest 는 컨테이너를 띄우지 않아 빠르다.

```yaml
      - name: Lint and test
        run: |
          npm run lint
          npm test
```

### 프론트 빌드 변수는 Variables 로 관리한다

Vite 는 **빌드 시점에 `VITE_*` 값을 번들에 박는다.**
런타임 주입이 불가능하므로 값을 바꾸려면 재빌드해야 한다.

```yaml
      - name: Build
        env:
          VITE_API_BASE_URL: ${{ vars.VITE_API_BASE_URL }}
          VITE_USE_MOCKS: ${{ vars.VITE_USE_MOCKS }}
          VITE_KAKAO_CLIENT_ID: ${{ vars.VITE_KAKAO_CLIENT_ID }}
          VITE_KAKAO_REDIRECT_URI: ${{ vars.VITE_KAKAO_REDIRECT_URI }}
          VITE_CHAT_REALTIME: ${{ vars.VITE_CHAT_REALTIME }}
        run: npm run build
```

**Secrets 가 아니라 Variables 다.**
번들은 브라우저로 전달되므로 비밀을 넣을 수 없다.
카카오 REST API 키처럼 공개되어도 되는 값만 여기 둔다.

**워크플로에 기본값을 두지 않는다.**
`${{ vars.X || 'true' }}` 형태로 쓰면 값이 코드와 설정 두 곳에 흩어진다.
Variables 만 보고 현재 빌드 설정을 알 수 있어야 한다.

대신 누락 시 조용히 빈 문자열이 되므로, 중요한 값은 경고를 남긴다.

```yaml
      - name: Check Kakao client id
        if: vars.VITE_KAKAO_CLIENT_ID == ''
        run: echo "::warning::VITE_KAKAO_CLIENT_ID 가 없습니다."
```

**값을 바꾸면 재빌드해야 반영된다.** 빈 커밋으로 PR 을 만들어 트리거한다.

```bash
git commit --allow-empty -m "chore: rebuild for variable change"
```

### gitops 레포 갱신

```yaml
      - name: Update image tags
        env:
          IMAGE_TAG: ${{ needs.retag.outputs.image_tag }}
          API_CHANGED: ${{ needs.changes.outputs.api }}
          CHAT_CHANGED: ${{ needs.changes.outputs.chat }}
        run: |
          if [ "$API_CHANGED" = "true" ]; then
            sed -i "s|^  tag: .*|  tag: \"${IMAGE_TAG}\"|" apps/reused-api/values.yaml
          fi
          if [ "$CHAT_CHANGED" = "true" ]; then
            sed -i "s|^  tag: .*|  tag: \"${IMAGE_TAG}\"|" apps/reused-chat/values.yaml
          fi
```

**`yq` 가 아니라 `sed` 를 쓴다.**

`yq -i` 는 파일을 파싱해 다시 쓰면서 **빈 줄과 주석 위치를 바꾼다.**
한 줄만 고쳐도 diff 가 20줄이 되어 배포 이력을 읽기 어려워진다.

들여쓰기 2칸을 패턴에 넣어 `image:` 아래의 `tag` 만 매칭한다.

### GitHub App 으로 gitops 에 쓴다

```yaml
      - name: Generate token
        id: token
        uses: actions/create-github-app-token@v2
        with:
          app-id: ${{ secrets.GITOPS_APP_ID }}
          private-key: ${{ secrets.GITOPS_APP_PRIVATE_KEY }}
          owner: Logssey
          repositories: gitops
```

| 방식 | 판단 |
| --- | --- |
| Personal Access Token | 개인 계정에 종속. 퇴사·계정 변경에 취약 |
| Deploy Key | **조직 정책으로 차단됨** |
| **GitHub App** | 설치 범위가 명확. 토큰이 1시간 뒤 만료 |

Deploy Key 를 먼저 시도했으나 조직 설정에서 막혀 있었다.
GitHub App 이 결과적으로 더 나은 선택이었다. 레포 단위로 권한을 주고
토큰이 자동 만료되기 때문이다.

### 무료 플랜의 제약

| 기능 | 상태 |
| --- | --- |
| 조직 수준 Secret | **불가.** 레포마다 등록해야 한다 |
| Environment Required reviewers | **불가** |

Secret 을 레포마다 등록하는 것은 관리 부담이다.
특히 GitHub App 개인키를 교체하면 **모든 레포에서 갱신**해야 한다.
한 곳을 빠뜨리면 그 레포의 배포만 실패한다.

`environment: production` 은 승인 게이트로 쓸 수 없으나
배포 이력이 Environments 탭에 남으므로 기록용으로 유지한다.

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
    reused-chat/
    reused-web/
  argocd/
    appproject.yaml
    applicationset.yaml
  README.md
```

| 디렉터리 | 내용 |
| --- | --- |
| `apps/` | 애플리케이션 Helm 차트 |
| `argocd/` | AppProject, ApplicationSet |

**Kubernetes 리소스와 Argo CD 리소스를 섞지 않는다.**
성격과 변경 주체가 다르기 때문이다.

### Helm 차트를 여기에 두는 이유

차트 전체를 gitops 레포에 둔다.
앱 레포에 차트를 두고 values 만 gitops 에 두는 방식도 있으나,
**백엔드와 프론트엔드 중 어디에 둘지 정할 수 없다.**

레포 분리의 3번 근거와 같은 이유다.

### 차트 구성

`helm create` 로 만든 뒤 필요 없는 것을 지우고 셋을 더한다.

| 파일 | 용도 |
| --- | --- |
| `templates/configmap.yaml` | 비밀이 아닌 환경변수 |
| `templates/externalsecret.yaml` | ESO 가 읽을 시크릿 참조 |
| `templates/httproute.yaml` | Gateway API 라우팅 |

`ingress.yaml`, `NOTES.txt`, `tests/` 는 지운다.
Gateway API 를 쓰므로 Ingress 는 필요 없다.

**ConfigMap 변경 시 Pod 가 재시작되게 한다.**

```yaml
  template:
    metadata:
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

환경변수는 Pod 기동 시 한 번만 읽으므로 ConfigMap 만 바꾸면 반영되지 않는다.
해시를 어노테이션에 넣으면 내용이 바뀔 때 Pod 템플릿이 달라져 롤링 업데이트가 일어난다.

**Secret 은 이 방법이 통하지 않는다.** 값이 차트 안에 없고 ESO 가
런타임에 채우기 때문이다. 시크릿을 바꾸면 수동으로 재시작한다.

```bash
kubectl -n reused rollout restart deployment reused-api
```

### 환경 구분

**브랜치로 환경을 나누지 않는다.**

환경 간 병합이 발생하면 환경별로 달라야 할 값까지 섞인다.
Argo CD 관련 가이드가 공통으로 지적하는 안티패턴이다.

현재는 prod 하나뿐이므로 `values.yaml` 만 둔다.
환경이 늘면 `values-prod.yaml` 처럼 파일로 나눈다.

---

## Argo CD

### 설치

`infrastructure` 에서 Helm 으로 설치한다.

| 항목 | 값 |
| --- | --- |
| 차트 | `argo/argo-cd` 10.9.2 |
| 앱 버전 | v3.5.3 |
| 네임스페이스 | `argocd` |

**Argo CD 는 자기 자신을 관리할 수 없다.**
클러스터를 재구축할 때 Argo CD 가 없는 상태에서 시작하므로
부트스트랩은 수동이어야 한다.

```
클러스터 생성 → CNI → CSI → Gateway → Argo CD 설치 → ApplicationSet 적용
                                                          ↓
                                                    이후 GitOps
```

주요 values.

```yaml
configs:
  params:
    server.insecure: true    # TLS 종단이 앞단에 있다

dex:
  enabled: false             # SSO 미사용

notifications:
  enabled: false             # 알림 미구성
```

`server.insecure` 를 켠 것은 포트포워딩으로 접근하기 때문이다.
외부 노출 시에는 앞단에서 TLS 를 종단한다.

### gitops 레포 자격증명

Argo CD 가 private 레포를 읽으려면 자격증명이 필요하다.
CI 와 같은 GitHub App 을 쓴다.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: gitops-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/Logssey/gitops
  githubAppID: "5070612"
  githubAppInstallationID: "164719127"
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    ...
```

**라벨이 없으면 Argo CD 가 인식하지 못한다.**

### ApplicationSet — App of Apps 를 대체한다

초안에서는 App of Apps 패턴을 계획했으나 ApplicationSet 으로 바꿨다.

| 방식 | 내용 |
| --- | --- |
| App of Apps | root Application 이 Application YAML 들을 배포 |
| **ApplicationSet** | **디렉터리를 스캔해 Application 을 생성** |

Application YAML 을 서비스마다 손으로 쓰지 않아도 된다.
구조가 같은 애플리케이션이 여럿일 때 유리하다.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: reused
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/Logssey/gitops
        revision: main
        directories:
          - path: apps/*
  template:
    metadata:
      name: '{{path.basename}}'
    spec:
      project: reused
      source:
        repoURL: https://github.com/Logssey/gitops
        targetRevision: main
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: reused
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

`apps/reused-chat/` 을 추가하면 **Application 이 자동으로 생긴다.**
채팅 게이트웨이를 붙일 때 실제로 그랬다.

### AppProject 와 CreateNamespace

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: reused
  namespace: argocd
spec:
  sourceRepos:
    - https://github.com/Logssey/gitops
  destinations:
    - server: https://kubernetes.default.svc
      namespace: reused
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
```

**`clusterResourceWhitelist` 에 Namespace 를 넣어야 한다.**

`CreateNamespace=true` 는 Argo CD 가 Namespace 를 만들게 하는데,
Namespace 는 클러스터 범위 리소스다. AppProject 가 그것을 허용하지 않으면
sync 가 실패한다.

이것 외에는 클러스터 범위 리소스를 허용하지 않는다.
애플리케이션이 ClusterRole 이나 CRD 를 만들 이유가 없다.

### 동기화 정책

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

### 폴링 주기와 수동 트리거

기본 폴링 주기는 3분이다. 급할 때는 수동으로 트리거한다.

```bash
kubectl -n argocd patch application reused-api --type merge -p '{"operation":{"sync":{}}}'
```

웹훅을 걸면 즉시 반영되나, private 레포라 GitHub 에서 클러스터로 들어오는
경로를 열어야 한다. 확장 항목으로 둔다.

### 접근 방법

초기에는 포트포워딩으로 접근한다.

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

**외부 노출은 인증 설정을 전제로 한다.**
와일드카드 인증서가 있어 `argocd.re-used.store` 로 노출할 수 있으나,
기본 admin 계정을 공개하는 것은 위험하다.
GitHub OAuth 연동이 필요하다. 확장 항목으로 둔다.

---

## Secret 관리

### External Secrets Operator

AWS Secrets Manager 의 값을 Kubernetes Secret 으로 동기화한다.

```
AWS Secrets Manager
      ↓ ESO 가 주기적으로 조회 (refreshInterval)
Kubernetes Secret
      ↓ envFrom
   Pod
```

**Git 에는 참조만 남는다.** 값은 들어가지 않는다.

| 항목 | 값 |
| --- | --- |
| 차트 | `external-secrets/external-secrets` 2.11.0 |
| 네임스페이스 | `external-secrets` |
| API 버전 | `external-secrets.io/v1` |

### ClusterSecretStore

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-northeast-1
```

**`auth` 블록이 없다.** AWS SDK 의 기본 자격증명 체인이 노드 IAM Role 을
찾아 쓰기 때문이다.

### ExternalSecret

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: reused-api
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: reused-api
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: reused/prod/api
```

`dataFrom.extract` 는 **시크릿의 JSON 키를 그대로 Secret 키로 만든다.**
키를 하나씩 매핑하지 않아도 되지만, **시크릿 전체를 가져온다.**

### 서비스별로 시크릿을 나눈 이유

| 시크릿 | 키 |
| --- | --- |
| `reused/prod/api` | JWT_SECRET, SPRING_DATASOURCE_PASSWORD, SPRING_DATA_REDIS_PASSWORD, KAKAO_CLIENT_SECRET, MAIL_USERNAME, MAIL_PASSWORD, GEMINI_API_KEY |
| `reused/prod/chat` | CHAT_REDIS_URL |

`dataFrom.extract` 가 전체를 가져오므로 **하나로 합치면 채팅 Pod 가
JWT_SECRET 과 DB 비밀번호까지 갖게 된다.**

채팅 게이트웨이는 JWT 를 검증하지 않는다. 토큰을 Spring API 에 전달해
확인만 받는 구조다. 그 설계를 시크릿 범위로도 지킨다.

### 왜 ESO 인가

**이미 AWS Secrets Manager 와 SSM Parameter Store 를 쓰고 있다.**

| 방식 | 언제 쓰나 | 판단 |
| --- | --- | --- |
| **ESO** | 외부 시크릿 저장소가 이미 있을 때 | **채택** |
| Sealed Secrets | 외부 저장소 없이 Git 에 암호화해 넣을 때 | 미채택 |
| HashiCorp Vault | 멀티클라우드, 동적 시크릿, 대규모 조직 | 미채택 |

**Vault 는 규모에 비해 과하다.**
HA 구성에 노드 3~5대가 필요하고 unseal, 업그레이드, 백업 부담이 따른다.

**Sealed Secrets 는 맞지 않는다.**
외부 저장소가 없을 때의 선택인데 우리는 이미 있다.

### 설치를 둘로 나눈다

| 대상 | 위치 | 이유 |
| --- | --- | --- |
| ESO 오퍼레이터 | `infrastructure` | CRD 가 먼저 등록되어야 한다 |
| ClusterSecretStore | `infrastructure` | 클러스터 단위 설정 |
| **ExternalSecret** | **`gitops`** | 애플리케이션과 함께 변한다 |

전부 Argo CD 로 관리하면 CRD 등록 전에 CR 을 적용하려다 실패할 수 있다.
sync wave 로 해결할 수 있으나 디버깅이 복잡해진다.

반대로 전부 `infrastructure` 에 두면
애플리케이션 시크릿을 추가할 때마다 `helm upgrade` 를 수동 실행해야 한다.

### 시크릿을 바꾸면

ESO 는 `refreshInterval` 주기로만 조회한다. 즉시 반영하려면 어노테이션으로
강제 동기화한다.

```bash
kubectl -n reused annotate externalsecret reused-api \
  force-sync=$(date +%s) --overwrite
```

```bash
kubectl -n reused get secret reused-api -o jsonpath='{.data}' \
  | python3 -c "import sys,json; print(list(json.load(sys.stdin).keys()))"
```

**Kubernetes Secret 이 갱신돼도 Pod 는 모른다.**
환경변수는 기동 시 한 번만 읽으므로 재시작해야 한다.

```bash
kubectl -n reused rollout restart deployment reused-api
```

### IAM 권한

노드 IAM Role 에 Secrets Manager 읽기 권한을 추가한다.

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

**Git 에 두면 Argo CD 가 Git 값으로 되돌리고 HPA 가 다시 바꾸는 싸움이 난다.**

현재는 HPA 를 쓰지 않으므로 `replicaCount: 2` 를 values 에 둔다.
HPA 를 켤 때 제거한다.

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
aws ecr describe-repositories --region ap-northeast-1 \
  --query 'repositories[].[repositoryName,repositoryUri]' --output table
```

```bash
aws ecr list-images --repository-name logssey/reused-api \
  --region ap-northeast-1 --query 'imageIds[].imageTag' --output table
```

머지 후에는 `pr-{SHA}` 와 `{SHA}` 가 **같은 다이제스트에** 붙어 있어야 한다.

```bash
aws ecr describe-images --repository-name logssey/reused-api \
  --region ap-northeast-1 \
  --query 'imageDetails[0].[imageDigest,imageTags]' --output json
```

### OIDC Provider

```bash
aws iam get-role --role-name logssey-prod-role-github-actions \
  --query 'Role.AssumeRolePolicyDocument' --output json
```

`sub` 조건에 와일드카드가 들어간 레포 패턴과 `pull_request` 가 있어야 한다.

### Argo CD

```bash
kubectl -n argocd get applications
```

```
NAME          SYNC STATUS   HEALTH STATUS
reused-api    Synced        Healthy
reused-chat   Synced        Healthy
reused-web    Synced        Healthy
```

배포된 이미지 태그 확인.

```bash
kubectl -n reused get deploy reused-api \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

gitops 레포의 값과 일치해야 한다.

```bash
grep -A3 "^image:" apps/reused-api/values.yaml
```

### ExternalSecret

```bash
kubectl -n reused get externalsecret
```

```
NAME          STORE                 REFRESH INTERVAL   STATUS         READY
reused-api    aws-secrets-manager   1h                 SecretSynced   True
reused-chat   aws-secrets-manager   1h                 SecretSynced   True
```

키 목록 확인. **값은 출력하지 않는다.**

```bash
kubectl -n reused get secret reused-api -o jsonpath='{.data}' \
  | python3 -c "import sys,json; print(list(json.load(sys.stdin).keys()))"
```

Pod 에 주입됐는지 확인.

```bash
kubectl -n reused exec deploy/reused-api -- env \
  | grep -E "^(SPRING|APP|KAKAO|MAIL|JWT|GEMINI)" \
  | sed -E 's/(PASSWORD|SECRET|KEY)=.*/\1=***/' | sort
```

---

## 운영 메모

**gitops 레포는 CI 봇이 커밋한다.**
로컬에서 작업할 때 pull 을 습관화하지 않으면 push 가 거부된다.

```bash
git pull --rebase origin main
```

**프론트 빌드 변수를 바꾸면 재빌드해야 한다.**
Variables 만 고치고 끝내면 배포된 번들은 그대로다.

**CloudFront 캐시로 옛 응답이 굳으면 무효화한다.**

```bash
aws cloudfront create-invalidation \
  --distribution-id EYTWHIBCVO5FY --paths "/*" --region us-east-1
```

---

## 관련 트러블슈팅

| 문서 | 내용 |
| --- | --- |
| [09](troubleshooting/09-ecr-credential-provider.md) | kubelet 이 ECR 이미지를 받지 못함 |
| [10](troubleshooting/10-container-nonroot.md) | `runAsNonRoot` 와 이미지의 전제 |
| [11](troubleshooting/11-cloudfront-host-header.md) | CloudFront Host 헤더 교체 |
| [12](troubleshooting/12-redis-acl-pubsub.md) | Redis ACL pubsub 권한 |

---

## 확장 항목

| 항목 | 시점 |
| --- | --- |
| Trivy 이미지 스캔 | 보안 스캔 단계. Prowler, Gitleaks 와 함께 |
| Gitleaks | 같음. 커밋 전 시크릿 검출 |
| ECR credential provider user_data 이관 | Worker 노드 추가·재생성 대응 |
| Argo CD 외부 노출 + GitHub OAuth | 팀이 늘거나 원격 접근이 필요할 때 |
| Argo CD Notifications | 배포 결과를 Slack 등으로 알릴 때 |
| 웹훅 | 폴링 지연을 줄일 때. 기본 3분 |
| IRSA | Pod 단위 IAM 권한이 필요할 때 |
| Argo Rollouts | 카나리·블루그린 배포가 필요할 때 |
| staging 환경 | 검증 단계가 필요할 때 |
| CI 에서 통합 테스트 | Testcontainers 실행 시간을 감수할 수 있을 때 |