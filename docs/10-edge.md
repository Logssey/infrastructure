# 10. 엣지 — ACM, CloudFront, WAF

## 참고 문서

| 항목 | 링크 |
| --- | --- |
| ACM 인증서 발급 | https://docs.aws.amazon.com/acm/latest/userguide/gs-acm-request-public.html |
| CloudFront 대체 도메인 | https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/CNAMEs.html |
| ELB 보안 정책 | https://docs.aws.amazon.com/elasticloadbalancing/latest/network/describe-ssl-policies.html |
| CloudFront 캐시 동작 | https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/distribution-web-values-specify.html |
| CloudFront 관리형 정책 | https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html |
| WAF 관리형 룰 그룹 | https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-list.html |

---

## 전체 경로

```
클라이언트
   ↓ HTTPS 443
CloudFront                    WAF 연결, 캐싱, TLS 종단 (us-east-1 인증서)
   ↓ HTTPS 443
Public NLB                    TLS 종단 (ap-northeast-1 인증서)
   ↓ TCP 30080 (평문)
Worker NodePort
   ↓
Envoy Proxy
   ↓ HTTPRoute
Backend Service
```

TLS 는 **두 번 종단된다.** 클라이언트 → CloudFront 구간과
CloudFront → NLB 구간이 각각 다른 인증서를 사용한다.

NLB → Envoy 구간은 VPC 내부이므로 평문이다.

## 도메인 구성

| 도메인 | 대상 | 인증서 리전 |
| --- | --- | --- |
| `re-used.store` | CloudFront | us-east-1 |
| `www.re-used.store` | CloudFront | us-east-1 |
| `origin.re-used.store` | Public NLB | ap-northeast-1 |

`www` 는 apex 와 같은 CloudFront 배포를 가리킨다.
리다이렉트하지 않고 두 주소 모두 동일한 콘텐츠를 제공한다.

**중복 콘텐츠 문제**는 프론트엔드에서 canonical 태그로 처리한다.

```html
<link rel="canonical" href="https://re-used.store/..." />
```

SEO 요구가 커지면 CloudFront Function 으로 301 리다이렉트를 추가한다.

---

## 모듈 구조

엣지 계층은 세 모듈로 나뉜다.

| 모듈 | 리소스 |
| --- | --- |
| `dns` | Route53 Hosted Zone, ACM 인증서, 검증 레코드 |
| `lb` | Internal NLB, Public NLB, TLS 리스너 |
| `edge` | CloudFront, WAF, 서비스 레코드 |

의존 방향은 `dns → lb → edge` 로 선형이다.

### 왜 나누었는가

처음에는 Route53 과 CloudFront 를 한 모듈에 두었으나
**순환 참조가 발생했다.**

```
edge → lb : TLS 리스너에 필요한 인증서 ARN
lb  → edge : origin 레코드에 필요한 NLB DNS
```

Terraform 은 모듈 간 순환을 허용하지 않는다.
순환은 대개 설계 문제의 신호이며, 공유 리소스를 별도 모듈로
추출하는 것이 일반적인 해결책이다.

인증서를 `dns` 모듈로 분리하자 의존이 선형이 되었다.

```
dns  (Hosted Zone + 인증서)
 ↓
lb   (인증서로 TLS 리스너 구성)
 ↓
edge (Hosted Zone·NLB 정보로 레코드와 CloudFront 구성)
```

---

## ACM

### 리전 분리

**CloudFront 는 us-east-1 리전의 인증서만 사용할 수 있다.**
다른 리전에서 발급한 인증서는 연결되지 않는다.

NLB 는 자신이 속한 리전의 인증서를 사용하므로 ap-northeast-1 이 필요하다.

| 리전 | 도메인 | SAN | 사용처 |
| --- | --- | --- | --- |
| us-east-1 | `re-used.store` | `*.re-used.store` | CloudFront |
| ap-northeast-1 | `origin.re-used.store` | 없음 | Public NLB |

**와일드카드는 apex 를 포함하지 않는다.**
`*.re-used.store` 는 `www.re-used.store` 를 커버하지만
`re-used.store` 자체는 커버하지 않는다.
따라서 apex 를 주 도메인으로 두고 와일드카드를 SAN 으로 추가한다.

와일드카드를 넣어두면 향후 서브도메인(`grafana.re-used.store` 등)을
추가할 때 인증서를 새로 발급하지 않아도 된다.

### Terraform provider alias

us-east-1 리소스를 만들려면 별도 provider 설정이 필요하다.

```hcl
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = { ... }
  }
}
```

`default_tags` 는 provider 마다 독립적이므로 다시 선언해야 한다.

모듈에서 두 provider 를 쓰려면 `configuration_aliases` 로 선언하고
루트에서 전달한다.

```hcl
# modules/dns/versions.tf
terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.us_east_1]
    }
  }
}
```

```hcl
# environments/prod/main.tf
module "dns" {
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  ...
}
```

`dns` 와 `edge` 모듈이 각각 이 provider 를 받는다.
`dns` 는 인증서를, `edge` 는 WAF Web ACL 을 us-east-1 에 만든다.

### DNS 검증

Route53 Hosted Zone 이 이미 있으므로 DNS 검증을 사용한다.

| 방식 | 특징 |
| --- | --- |
| **DNS** | CNAME 레코드 추가. 자동 갱신 |
| Email | 도메인 등록 정보의 메일로 승인. 수동 |

**DNS 검증은 인증서 자동 갱신을 지원한다.**
검증 레코드를 남겨두면 만료 전 ACM 이 자동으로 갱신한다.
Email 검증은 매번 수동 승인이 필요하다.

Terraform 이 검증 레코드 생성과 대기를 처리한다.

```hcl
resource "aws_acm_certificate" "cloudfront" {
  provider = aws.us_east_1

  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cloudfront_validation" {
  for_each = { for dvo in ... : dvo.domain_name => dvo }
  ...
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cloudfront" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for r in aws_route53_record.cloudfront_validation : r.fqdn]
}
```

`aws_acm_certificate_validation` 은 검증 완료까지 대기한다.
이 리소스를 참조하면 인증서가 준비된 뒤에 NLB 리스너와 CloudFront 가 생성된다.

**apex 와 와일드카드는 같은 검증 레코드를 사용한다.**

```
_c1247be4e27b9f7f4d1a76573ab0a991.re-used.store.
  → _ad0da13704a182dc31821420f1f0a07f.wzccmgtwzk.acm-validations.aws.
```

`for_each` 의 키를 `domain_name` 으로 두면 Terraform 은 두 항목으로 관리하나
실제 Route53 레코드는 하나로 합쳐진다.
`allow_overwrite` 가 없으면 두 번째 항목이
"레코드가 이미 존재한다" 에러로 실패한다.

### 발급 시간

DNS 검증은 레코드 생성 후 수 분 내에 완료된다.
본 환경에서는 2분 이내에 두 인증서 모두 `ISSUED` 가 되었다.

### 비용

ACM 퍼블릭 인증서는 무료다. 갱신도 무료다.

---

## Public NLB TLS 리스너

### 구성

| 항목 | 값 |
| --- | --- |
| 프로토콜 | TLS |
| 포트 | 443 |
| 인증서 | ACM ap-northeast-1 |
| SSL Policy | `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09` |
| 타겟 그룹 | logssey-prod-tg-envoy (TCP 30080) |

리스너를 교체해도 타겟 그룹은 영향받지 않는다.
80 에서 443 으로 바꾼 뒤에도 Worker 3대가 healthy 를 유지했다.

### HTTP 80 리스너 제거

**80 리스너를 제거한다.**

CloudFront 가 `redirect-to-https` 로 클라이언트의 HTTP 요청을 처리하므로
CloudFront → NLB 구간은 항상 HTTPS 다. 80 은 사용되지 않는다.

NLB 는 L4 라 리다이렉트를 할 수 없다. ALB 의 기능이다.
따라서 열거나 닫는 선택만 가능하다.

의도적 취약 설정으로 남길 수도 있으나 제외했다.
**실무에서 흔히 놓치는 항목과 반드시 처리하는 항목을 구분**한다.
평문 리스너를 열어두는 것은 후자에 해당하며, 스캔 재료로서 가치가 낮다.

### SSL Policy

**Terraform 기본값은 `ELBSecurityPolicy-2016-08` 이다.**
호환성을 우선한 정책이라 구버전 프로토콜을 포함한다.
명시하지 않으면 이 값이 적용되어 스캐너에 검출된다.

| 정책 | 특징 |
| --- | --- |
| `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09` | AWS 권장. PQ + TLS 1.3/1.2 |
| `ELBSecurityPolicy-TLS13-1-2-2021-06` | TLS 1.3/1.2 |
| `ELBSecurityPolicy-2016-08` | 기본값. 구버전 포함 |

AWS 는 포스트 양자 암호 기반 정책 도입을 권장한다.
하이브리드 PQ-TLS, TLS 1.3, TLS 1.2 클라이언트를 모두 수용해
전환 중 중단이 없다.

본 환경의 클라이언트는 CloudFront 뿐이므로 호환성 문제가 없다.

사용 가능한 정책 조회.

```bash
aws elbv2 describe-ssl-policies \
  --load-balancer-type network \
  --region ap-northeast-1 \
  --query "SslPolicies[?contains(SslProtocols,'TLSv1.3')].Name" \
  --output text | tr '\t' '\n'
```

### 오리진 직접 접근 차단

`sg-public-nlb` 는 CloudFront 의 `origin-facing` prefix list 로만 443 을 허용한다.

```hcl
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}
```

`origin.re-used.store` 가 공개 도메인이지만 **CloudFront 를 거치지 않은
접근은 SG 에서 차단된다.** 로컬에서 직접 curl 하면 타임아웃이 발생하며
이것이 정상 동작이다.

`com.amazonaws.global.cloudfront` 는 CloudFront 전체 IP 로 범위가 더 넓다.
오리진 접근에는 `origin-facing` 이 적절하다.

---

## Route53

| 레코드 | 타입 | 대상 |
| --- | --- | --- |
| `re-used.store` | A, AAAA (alias) | CloudFront |
| `www.re-used.store` | A, AAAA (alias) | CloudFront |
| `origin.re-used.store` | A (alias) | Public NLB |

**alias 레코드를 사용한다.**

| 항목 | alias | CNAME |
| --- | --- | --- |
| apex 도메인 | 가능 | **불가** |
| 조회 비용 | 무료 | 과금 |
| 조회 단계 | 1회 | 2회 |

DNS 표준상 apex 에는 CNAME 을 둘 수 없다.
Route53 alias 는 A 레코드처럼 동작하면서 AWS 리소스를 가리킬 수 있다.

### IPv6

CloudFront 는 `is_ipv6_enabled = true` 로 IPv6 를 지원하므로
AAAA 레코드도 함께 만든다. alias 레코드는 추가 비용이 없다.

NLB 는 현재 IPv4 전용이므로 `origin` 은 A 레코드만 둔다.

### Hosted Zone ID

CloudFront 의 Hosted Zone ID 는 전역 고정값 `Z2FDTNDATAQYW2` 이나
`aws_cloudfront_distribution.main.hosted_zone_id` 속성으로 참조해
하드코딩을 피한다.

NLB 는 리전마다 다르며 `aws_lb.public.zone_id` 로 참조한다.

### evaluate_target_health

모든 alias 레코드에서 `false` 로 둔다.

`true` 면 대상이 전부 unhealthy 일 때 DNS 응답 자체가 사라져
장애 원인 파악이 어려워진다.

---

## CloudFront

### 기본 설정

| 항목 | 값 |
| --- | --- |
| Aliases | `re-used.store`, `www.re-used.store` |
| 인증서 | ACM us-east-1 |
| Minimum TLS | TLSv1.2_2021 |
| Price Class | `PriceClass_200` |
| Viewer Protocol | `redirect-to-https` |
| Origin Protocol | `https-only` |
| Origin | `origin.re-used.store` |
| IPv6 | 활성 |
| 로깅 | 비활성 |

### Price Class

| 값 | 엣지 로케이션 | 비용 |
| --- | --- | --- |
| `PriceClass_All` | 전 세계 | 높음 |
| **`PriceClass_200`** | 북미·유럽·아시아·중동·아프리카 | 중간 |
| `PriceClass_100` | 북미·유럽 | 낮음 |

한국 사용자 대상이므로 아시아 엣지가 필요하다.
`PriceClass_100` 은 아시아를 제외해 응답이 느려진다.

실제로 한국에서 접속하면 서울 엣지(`ICN53`)로 연결된다.
응답 헤더의 `x-amz-cf-pop` 으로 확인할 수 있다.

### Origin

CloudFront 는 `origin.re-used.store` 로 NLB 에 연결한다.

**Custom Origin 에 HTTPS 로 연결하려면 오리진 도메인에 대한
퍼블릭 신뢰 인증서가 필요하다.** NLB 의 DNS 이름
(`logssey-prod-nlb-public-*.elb.amazonaws.com`)으로는 인증서를 발급할 수 없어
별도 도메인을 두었다.

| 항목 | 값 |
| --- | --- |
| Origin Domain | `origin.re-used.store` |
| Origin Protocol Policy | `https-only` |
| Origin SSL Protocols | TLSv1.2 |

### Behavior

`docs/07-ingress.md` 의 Path 기반 라우팅과 같은 규칙을 공유한다.

| 순서 | Path | 캐시 정책 | 오리진 요청 정책 | 압축 |
| --- | --- | --- | --- | --- |
| 1 | `/api/*` | CachingDisabled | AllViewer | 활성 |
| 2 | `/socket.io/*` | CachingDisabled | AllViewer | 비활성 |
| 3 | `/assets/*` | CachingOptimized | 없음 | 활성 |
| — | Default (`*`) | CachingOptimized | 없음 | 활성 |

**Behavior 는 선언 순서대로 평가된다.** 먼저 매칭되는 규칙이 적용되므로
구체적인 경로를 앞에 둔다.

#### 관리형 정책

AWS 관리형 정책을 data source 로 참조한다.
직접 정의할 수도 있으나 관리형 정책이 일반적인 요구를 충족한다.

| 정책 | 동작 |
| --- | --- |
| `Managed-CachingDisabled` | 캐싱하지 않음 |
| `Managed-CachingOptimized` | 압축 활성, 쿼리스트링·쿠키·헤더를 캐시 키에서 제외 |
| `Managed-AllViewer` | 뷰어의 모든 헤더·쿠키·쿼리스트링을 오리진에 전달 |

```hcl
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}
```

#### WebSocket

**`Upgrade` 와 `Connection` 헤더가 오리진에 전달되어야 한다.**
`AllViewer` 오리진 요청 정책이 이를 포함한다.

CloudFront 는 WebSocket 을 기본 지원하며 별도 설정이 필요 없다.

압축은 비활성화한다. WebSocket 프레임과 충돌할 수 있다.

#### 허용 메서드

| Behavior | allowed_methods | cached_methods |
| --- | --- | --- |
| `/api/*` | GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE | GET, HEAD |
| `/socket.io/*` | 같음 | GET, HEAD |
| `/assets/*` | GET, HEAD | GET, HEAD |
| Default | GET, HEAD, OPTIONS | GET, HEAD |

`cached_methods` 는 `allowed_methods` 의 부분집합이어야 한다.

### 로깅 미적용

표준 로깅은 S3 버킷과 저장 비용이 필요하다.
현재 트래픽이 없고 분석 체계도 없으므로 비활성화한다.

접근 로그가 필요해지면 활성화한다.
`docs/08-rds.md` 의 CloudWatch 로그 export 와 같은 판단이다.

### 배포 시간

**CloudFront 설정 변경은 전 세계 엣지에 전파되어야 한다.**
생성과 수정 모두 5~15분이 걸린다.

`terraform apply` 가 완료를 기다리므로 그만큼 시간이 소요된다.

---

## WAF

### 구성

| 항목 | 값 |
| --- | --- |
| Scope | CLOUDFRONT (us-east-1 에 생성) |
| 기본 동작 | Allow |
| 룰 동작 | **Count** |

**Web ACL 은 us-east-1 에 만들어야 한다.**
CloudFront 에 연결하는 Web ACL 은 리전이 고정되어 있다.

`waf_enabled` 변수로 연결 여부를 제어한다.
비활성화하면 Web ACL 자체가 생성되지 않아 과금이 없다.

### 관리형 룰 그룹

| 우선순위 | 룰 그룹 | 내용 |
| --- | --- | --- |
| 1 | `AWSManagedRulesCommonRuleSet` | OWASP 기반 공통 규칙 |
| 2 | `AWSManagedRulesKnownBadInputsRuleSet` | 알려진 악성 입력 패턴 |
| 3 | `AWSManagedRulesAmazonIpReputationList` | 평판이 낮은 IP 목록 |

AWS 가 관리하며 자동으로 갱신된다.

### Count 모드로 시작하는 이유

**Block 으로 바로 켜면 정상 요청이 차단될 수 있다.**

관리형 룰은 일반적인 공격 패턴을 기준으로 하므로,
애플리케이션의 정상 동작이 오탐으로 걸리는 경우가 있다.
파일 업로드, 긴 쿼리스트링, 특수문자를 포함한 입력 등이 대표적이다.

Count 모드는 매칭만 기록하고 요청은 통과시킨다.
실제 트래픽 패턴을 확인한 뒤 룰별로 Block 으로 전환한다.

```hcl
override_action {
  count {}
}
```

**`override_action` 은 룰 그룹 안의 개별 룰 동작을 덮어쓴다.**
관리형 룰 그룹의 개별 룰은 기본적으로 Block 이며,
이 설정으로 전부 Count 로 바뀐다.

매칭된 요청 샘플 조회.

```bash
aws wafv2 get-sampled-requests \
  --web-acl-arn $(terraform output -raw waf_web_acl_arn) \
  --rule-metric-name AWSManagedRulesCommonRuleSet \
  --scope CLOUDFRONT \
  --time-window StartTime=<t1>,EndTime=<t2> \
  --max-items 100 \
  --region us-east-1
```

### 비용

| 항목 | 월 (USD) |
| --- | --- |
| Web ACL | 5.00 |
| 관리형 룰 그룹 ×3 | 3.00 |
| 요청 (100만 건당 $0.60) | 0 |
| **합계** | **8.00** |

관리형 룰 그룹 하나가 룰 1개로 계산된다.

---

## 비용 요약

| 항목 | 월 (USD) |
| --- | --- |
| ACM 인증서 ×2 | 0 |
| Route53 Hosted Zone | 0.50 |
| Route53 쿼리 | 트래픽 기준 |
| CloudFront | 트래픽 기준 (월 1TB 무료 티어) |
| WAF | 8.00 |
| **합계** | **약 8.5** |

CloudFront 는 **매월 1TB 데이터 전송과 1000만 건 요청이 무료**다.
테스트 트래픽 규모에서는 과금되지 않는다.

**CloudFront 를 통하면 EC2 아웃바운드 요금이 절감된다.**
오리진으로 나가는 트래픽은 CloudFront 요금에 포함되어
NLB 에서 인터넷으로 직접 나가는 것보다 저렴하다.

---

## 확인

### ACM 인증서 상태

```bash
aws acm list-certificates \
  --region us-east-1 \
  --query 'CertificateSummaryList[].[DomainName,Status]' \
  --output table

aws acm list-certificates \
  --region ap-northeast-1 \
  --query 'CertificateSummaryList[].[DomainName,Status]' \
  --output table
```

`ISSUED` 여야 한다. `PENDING_VALIDATION` 이면 DNS 레코드 전파를 기다린다.

검증 레코드 확인.

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id $(terraform output -raw route53_zone_id) \
  --query "ResourceRecordSets[?Type=='CNAME'].[Name,ResourceRecords[0].Value]" \
  --output table
```

apex 와 와일드카드가 하나의 레코드를 공유하므로 CNAME 은 2개다.

### NLB 리스너

```bash
aws elbv2 describe-listeners \
  --load-balancer-arn $(terraform output -raw public_nlb_arn) \
  --region ap-northeast-1 \
  --query 'Listeners[].[Protocol,Port,SslPolicy]' \
  --output table
```

TLS 443 하나만 있어야 한다.

### Route53 레코드

```bash
dig re-used.store +short
dig www.re-used.store +short
dig re-used.store AAAA +short
dig origin.re-used.store +short
```

apex 와 www 는 CloudFront IP, origin 은 NLB IP 가 나온다.
Route53 이 라운드로빈으로 응답하므로 조회할 때마다 순서가 바뀐다.

### 오리진 직접 접속 — 차단 확인

```bash
curl -sS --max-time 10 -o /dev/null -w "%{http_code}\n" \
  https://origin.re-used.store/
```

**타임아웃이 정상이다.** SG 가 CloudFront IP 만 허용하므로
외부에서 오리진에 직접 접근할 수 없다.

### CloudFront 경유

```bash
curl -sS -o /dev/null -w "code=%{http_code}\n" https://re-used.store/
curl -sS -o /dev/null -w "code=%{http_code}\n" https://www.re-used.store/
```

**404 가 정상이다.** CloudFront → NLB → Envoy 까지 도달했고,
Envoy 에 매칭되는 HTTPRoute 가 없다는 뜻이다.

HTTP 리다이렉트 확인.

```bash
curl -sS -o /dev/null -w "code=%{http_code} -> %{redirect_url}\n" \
  http://re-used.store/
```

```
code=301 -> https://re-used.store/
```

### 응답 헤더

```bash
curl -sI https://re-used.store/ | head -10
```

```
HTTP/2 404
x-cache: Error from cloudfront
via: 1.1 <hash>.cloudfront.net (CloudFront)
x-amz-cf-pop: ICN53-P1
age: 4
```

| 헤더 | 의미 |
| --- | --- |
| `x-amz-cf-pop` | 응답한 엣지 로케이션. ICN 은 서울 |
| `x-cache` | 캐시 히트 여부 |
| `age` | 캐시된 후 경과 시간 |

**`x-cache: Error from cloudfront`** 는 오리진이 4xx/5xx 를 반환했다는 뜻이다.
404 응답도 기본 10초간 캐싱되므로 `age` 헤더가 나타난다.

라우트를 붙이면 `Miss from cloudfront` 또는 `Hit from cloudfront` 로 바뀐다.

| 값 | 의미 |
| --- | --- |
| `Miss from cloudfront` | 오리진에서 가져옴 |
| `Hit from cloudfront` | 캐시 응답 |
| `Error from cloudfront` | 오리진이 에러 반환 |

`/api/*` 는 캐싱을 비활성화했으므로 항상 Miss 여야 한다.

### WAF

```bash
aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 \
  --query 'WebACLs[].[Name,Id]' --output table
```

룰 구성 확인.

```bash
WAF_ID=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 \
  --query "WebACLs[?Name=='logssey-prod-waf'].Id" --output text)

aws wafv2 get-web-acl \
  --name logssey-prod-waf --scope CLOUDFRONT --id $WAF_ID \
  --region us-east-1 \
  --query 'WebACL.Rules[].[Name,Priority,OverrideAction]' \
  --output json
```

세 룰 모두 `{"Count": {}}` 여야 한다.

CloudFront 연결 확인.

```bash
aws cloudfront get-distribution \
  --id $(terraform output -raw cloudfront_distribution_id) \
  --query 'Distribution.DistributionConfig.WebACLId' \
  --output text
```

매칭 지표 확인.

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/WAFV2 \
  --metric-name CountedRequests \
  --dimensions Name=WebACL,Value=logssey-prod-waf Name=Rule,Value=ALL Name=Region,Value=CloudFront \
  --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 --statistics Sum \
  --region us-east-1
```

`Datapoints` 가 비어 있으면 어떤 룰에도 매칭되지 않은 것이다.
정상 요청만 발생한 상태에서는 이것이 기대값이다.

---

## 구축 결과 (2026-09-23)

| 항목 | 값 |
| --- | --- |
| CloudFront Distribution | EYTWHIBCVO5FY |
| 기본 도메인 | duo9ob5udgpq0.cloudfront.net |
| 상태 | Deployed |
| 엣지 (한국 접속 시) | ICN53-P1 |
| WAF | 연결됨, 룰 3개 Count |

전체 경로가 동작한다.

```
클라이언트 → CloudFront (ICN53) → Public NLB → Envoy → 404
```

---

## 확장 항목

| 항목 | 시점 |
| --- | --- |
| WAF Block 모드 전환 | 트래픽 패턴 확인 후 |
| WAF Rate limiting | 남용 발생 시 |
| CloudFront 로깅 | 접근 분석 필요 시 |
| www → apex 301 리다이렉트 | SEO 요구 발생 시 |
| CloudFront Function | 헤더 조작, A/B 테스트 등 필요 시 |
| Origin Access Control | S3 오리진 추가 시 |
| 커스텀 에러 페이지 | 프론트엔드 SPA 라우팅 대응 시 |
| 404 캐싱 TTL 조정 | 개발 중 응답 확인이 불편할 때 |

**SPA 라우팅 주의** — 프론트엔드가 클라이언트 사이드 라우팅을 쓰면
`/some/path` 직접 접속 시 오리진이 404 를 반환한다.
CloudFront 커스텀 에러 응답으로 404 를 `/index.html` 200 으로
변환하는 설정이 필요할 수 있다. 프론트엔드 구현 확정 후 판단한다.