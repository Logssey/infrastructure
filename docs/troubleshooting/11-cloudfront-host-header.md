# 11. 프론트엔드 404 — CloudFront 가 Host 헤더를 교체함

| 항목 | 내용 |
| --- | --- |
| 발생 | 2026-09-28 |
| 단계 | 프론트엔드 배포 후 검증용 리소스 정리 |
| 영향 | 외부에서 사이트 전체 404. 클러스터 내부는 정상 |
| 환경 | CloudFront, Envoy Gateway v1.9.1, Gateway API v1.6.1 |

## 배경

외부 진입 경로는 아래와 같다.

```
브라우저 → CloudFront → Public NLB → Envoy Gateway → Pod
```

CloudFront 오리진은 S3 가 아니라 NLB 다. NLB 기본 DNS 이름으로는
퍼블릭 인증서를 발급받을 수 없어 `origin.re-used.store` 서브도메인을
따로 두고 그것을 오리진 도메인으로 지정했다(`docs/10-edge.md`).

Envoy Gateway 구성을 검증할 때 `nginx-test` 라는 Deployment 와 HTTPRoute 를
`default` 네임스페이스에 만들어 두었고, 실제 서비스를 배포한 뒤에도
지우지 않고 있었다.

## 증상

프론트엔드 배포를 마치고 `nginx-test` 를 정리했다.

```bash
kubectl delete deployment,service,httproute nginx-test -n default
```

**그 직후 사이트 전체가 404 가 됐다.**

```bash
curl -sI "https://re-used.store/" | head -5
```

```
HTTP/2 404
x-cache: Error from cloudfront
via: 1.1 ...cloudfront.net (CloudFront)
x-amz-cf-pop: ICN53-P1
```

`reused-web` Pod 는 정상이었다.

```bash
kubectl -n reused get pods
# reused-web-6b48c9b7bd-jkx7n   1/1   Running   0   2m
```

Argo CD 도 `Synced / Healthy` 였다.

## 진단 과정

### 1. 캐시부터 의심 — 틀렸다

`x-cache: Error from cloudfront` 를 보고 404 가 캐시된 것으로 판단했다.
무효화를 실행했다.

```bash
aws cloudfront create-invalidation \
  --distribution-id EYTWHIBCVO5FY --paths "/*" --region us-east-1
```

```bash
aws cloudfront get-invalidation \
  --distribution-id EYTWHIBCVO5FY --id ICZXIJC8QYLJTY8ZAIBN25VIRP \
  --region us-east-1 --query 'Invalidation.Status' --output text
# Completed
```

**무효화가 끝난 뒤에도 404 였다.**

`x-cache: Error from cloudfront` 는 캐시된 에러를 반환했다는 뜻이 아니라
**오리진 응답이 에러였다**는 뜻이기도 하다. 이 값을 캐시 문제로만 읽은 것이
첫 오판이었다.

### 2. 클러스터 내부 확인 — 정상

Worker NodePort 에 직접 요청했다.

```bash
curl -sI -H "Host: re-used.store" http://10.20.10.20:30080/ | head -3
```

```
HTTP/1.1 200 OK
server: nginx/1.30.5
```

세 노드 모두 200 이었다.

```bash
for ip in 10.20.10.20 10.20.11.20 10.20.12.20; do
  echo -n "$ip: "
  curl -s -o /dev/null -w "%{http_code}\n" -H "Host: re-used.store" http://$ip:30080/
done
# 10.20.10.20: 200
# 10.20.11.20: 200
# 10.20.12.20: 200
```

**Envoy 와 Pod 는 문제가 없었다.**

### 3. NLB 확인 — 정상

```bash
TG_ARN=$(aws elbv2 describe-target-groups --region ap-northeast-1 \
  --names logssey-prod-tg-envoy --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --region ap-northeast-1 \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table
```

```
|  i-030605b5b05e1eb94 |  healthy  |
|  i-08aa421a354dcf78a |  healthy  |
|  i-0c18628fa30035aa9 |  healthy  |
```

오리진에 직접 붙어보려 했으나 SG 가 CloudFront prefix list 만 허용하므로
로컬에서는 도달할 수 없었다.

```bash
curl -sI -H "Host: re-used.store" https://origin.re-used.store/ --max-time 10
# (응답 없음)
```

### 4. CloudFront 설정 조회

```bash
aws cloudfront get-distribution-config --id EYTWHIBCVO5FY --region us-east-1 \
  --query 'DistributionConfig.{Origins:Origins.Items[].{Id:Id,Domain:DomainName},
    Default:DefaultCacheBehavior.TargetOriginId,
    Behaviors:CacheBehaviors.Items[].{Path:PathPattern,Origin:TargetOriginId}}'
```

```json
{
  "Origins": [{ "Id": "nlb-origin", "Domain": "origin.re-used.store" }],
  "Default": "nlb-origin",
  "Behaviors": [
    { "Path": "/api/*", "Origin": "nlb-origin" },
    { "Path": "/socket.io/*", "Origin": "nlb-origin" },
    { "Path": "/assets/*", "Origin": "nlb-origin" }
  ]
}
```

오리진과 라우팅은 정상이었다. 정책을 확인했다.

```bash
aws cloudfront get-distribution-config --id EYTWHIBCVO5FY --region us-east-1 \
  --query 'DistributionConfig.DefaultCacheBehavior.{Policy:CachePolicyId,
    OriginRequest:OriginRequestPolicyId}'
```

```json
{
  "Policy": "658327ea-f89d-4fab-a63d-7e88639e58f6",
  "OriginRequest": null
}
```

**`OriginRequestPolicyId` 가 `null` 이었다.**

`/api/*` 와 `/socket.io/*` 에는 `AllViewer` 가 붙어 있었다.
동적 요청에 인증 헤더와 쿠키를 전달해야 해서 설정한 것이었고,
default 와 `/assets/*` 는 정적 자산이라 필요 없다고 판단해 비워 두었다.

### 5. 가설 검증

CloudFront 가 Host 를 오리진 도메인으로 바꾼다면 Envoy 는
`origin.re-used.store` 를 받게 된다. NodePort 에 그 Host 로 요청했다.

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Host: origin.re-used.store" http://10.20.10.20:30080/
```

```
404
```

**재현됐다.**

## 원인

**CloudFront 는 오리진 요청 정책이 없으면 Host 헤더를 오리진 도메인으로 교체한다.**

공식 문서가 명시한다. 뷰어의 Host 를 제거하면
**오리진 도메인 이름으로 새 Host 헤더를 추가**한다.

```
브라우저      Host: re-used.store
                ↓
CloudFront    Host: origin.re-used.store   ← 교체
                ↓
NLB → Envoy
                ↓
HTTPRoute hostnames:
  - re-used.store
  - www.re-used.store        ← origin.re-used.store 가 없음
                ↓
              매칭 실패 → 404
```

### 왜 그동안 동작했는가

`nginx-test` 의 HTTPRoute 에 **hostnames 가 없었다.**

```
NAMESPACE   NAME         HOSTNAMES
default     nginx-test   (없음)
reused      reused-api   ["re-used.store","www.re-used.store"]
reused      reused-web   ["re-used.store","www.re-used.store"]
```

Gateway API 에서 hostnames 를 생략하면 **모든 Host 를 받는다.**
`origin.re-used.store` 로 와도 이 Route 가 잡아 nginx 로 보냈다.

검증용 리소스가 설정 오류를 덮고 있었던 것이다.
`nginx-test` 를 지우자 포괄 Route 가 사라지고 문제가 드러났다.

## 해결

### 대안 검토

| 안 | 내용 |
| --- | --- |
| A. HTTPRoute 에 `origin.re-used.store` 추가 | 한 줄이면 끝남 |
| **B. CloudFront 가 원본 Host 를 전달** | 표준. 애플리케이션이 실제 도메인을 봄 |

**A 는 증상만 없앤다.** 애플리케이션이 자기 주소를 `origin.re-used.store` 로
인식하게 되고, 그러면 아래가 전부 어긋난다.

| 항목 | A 의 결과 |
| --- | --- |
| 쿠키 도메인 | `origin.re-used.store` 로 설정되어 브라우저가 거부 |
| 리다이렉트 | `Location: https://origin.re-used.store/...` |
| 절대 URL 생성 | 잘못된 도메인 |
| OAuth 콜백 | 카카오 redirect_uri 불일치 |

백엔드가 리프레시 토큰을 쿠키로 내리므로 첫 항목만으로도 채택할 수 없다.

**B 를 택했다.**

### 관리형 정책을 쓰지 않은 이유

`Managed-AllViewer` 를 default 에도 붙이면 한 줄로 끝난다.
`/api/*` 가 이미 그것을 쓰고 있기도 하다.

다만 `AllViewer` 는 **모든 헤더·쿠키·쿼리스트링**을 전달한다.
정적 자산 요청에 세션 쿠키를 함께 보낼 이유가 없다.

캐싱은 영향받지 않는다. 오리진 요청 정책과 캐시 키는 별개이고
`CachingOptimized` 는 헤더를 캐시 키에 넣지 않기 때문이다.
그래도 **불필요한 데이터를 오리진에 보내지 않는 쪽**을 택했다.

### Terraform

**파일**: `terraform/modules/edge/cloudfront.tf`

```hcl
# ── Origin Request Policy — Host 만 전달 ──
#
# CloudFront 는 기본적으로 Host 를 오리진 도메인(origin.re-used.store)으로
# 바꿔서 보낸다. 그러면 HTTPRoute 의 hostnames 와 매칭되지 않아 404 가 난다.
#
# 뷰어가 보낸 Host 를 그대로 전달해야
# 애플리케이션이 쿠키 도메인과 리다이렉트 URL 을 올바르게 만든다.
#
# 정적 자산 요청에 쿠키를 함께 보낼 이유가 없어
# AllViewer 대신 Host 만 전달하는 정책을 둔다.
resource "aws_cloudfront_origin_request_policy" "host_only" {
  name    = "${var.name_prefix}-host-only"
  comment = "뷰어의 Host 헤더만 오리진으로 전달"

  headers_config {
    header_behavior = "whitelist"
    headers {
      items = ["Host"]
    }
  }

  cookies_config {
    cookie_behavior = "none"
  }

  query_strings_config {
    query_string_behavior = "none"
  }
}
```

default 와 `/assets/*` 에 적용한다.

```hcl
  default_cache_behavior {
    ...
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_optimized.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.host_only.id
    compress                 = true
  }
```

`/api/*` 와 `/socket.io/*` 는 `AllViewer` 를 유지한다.
전자는 인증 헤더와 쿠키가, 후자는 WebSocket 업그레이드에 쓰이는
`Upgrade`·`Connection` 헤더가 필요하다.

```bash
terraform plan
# Plan: 1 to add, 1 to change, 0 to destroy.
```

변경은 두 behavior 인데 `1 to change` 로 나온다.
Terraform 이 distribution 을 리소스 하나로 세기 때문이다.

```bash
terraform apply
```

**전파에 5~15분** 걸린다. apply 가 완료를 기다린다.

## 검증

```bash
curl -sI "https://re-used.store/" | head -5
```

```
HTTP/2 200
content-type: text/html
```

브라우저에서도 화면과 정적 자산이 정상 로드됐다.

## 재발 방지

**검증용 리소스는 목적을 달성하면 바로 지운다.**

`nginx-test` 는 Envoy Gateway 경로를 확인하려고 만든 것이었다.
목적을 달성한 시점에 지웠어야 했는데 남겨둔 탓에 **설정 오류가 몇 주 동안
드러나지 않았다.** 실제 서비스를 배포하고 정상 동작을 확인한 뒤였기에
문제가 없다고 판단하기 쉬운 상태였다.

**HTTPRoute 에 hostnames 를 생략하지 않는다.**

임시 리소스라도 hostname 을 지정해야 다른 Route 를 가리지 않는다.

```yaml
# 임시 리소스도 hostname 을 둔다
hostnames:
  - test.re-used.store
```

**CloudFront 뒤에서 Host 기반 라우팅을 쓰면 정책을 확인한다.**

| 상황 | 필요 |
| --- | --- |
| 오리진이 Host 로 분기 | 원본 Host 전달 필수 |
| 애플리케이션이 절대 URL 생성 | 같음 |
| 쿠키 도메인 설정 | 같음 |
| S3 오리진 | **전달하면 안 됨.** S3 는 자기 도메인이 아니면 거부 |

마지막 항목 때문에 CloudFront 의 기본값이 "교체"인 것이다.
S3 오리진이 일반적이라 그쪽에 맞춰져 있다.

**`x-cache: Error from cloudfront` 를 캐시 문제로만 읽지 않는다.**

이 값은 오리진 응답이 에러였을 때도 나온다. 무효화를 먼저 시도한 탓에
진단이 한 단계 늦어졌다. 클러스터 내부와 외부를 각각 확인해
구간을 나누는 것이 빨랐다.

## 참고

| 항목 | 내용 |
| --- | --- |
| 오리진 요청 정책 | https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/origin-request-understand-origin-request-policy.html |
| Host 헤더 전달 | https://repost.aws/knowledge-center/configure-cloudfront-to-forward-headers |
| 커스텀 오리진 동작 | https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/RequestAndResponseBehaviorCustomOrigin.html |
| Gateway API hostname | https://gateway-api.sigs.k8s.io/api-types/httproute/ |
| 엣지 구성 | `docs/10-edge.md` |
| Envoy Gateway 구성 | `docs/07-ingress.md` |