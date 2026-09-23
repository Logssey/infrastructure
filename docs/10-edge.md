# 10. 엣지 — ACM, CloudFront, WAF

## 참고 문서

| 항목 | 링크 |
| --- | --- |
| ACM 인증서 발급 | https://docs.aws.amazon.com/acm/latest/userguide/gs-acm-request-public.html |
| CloudFront 대체 도메인 | https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/CNAMEs.html |
| ELB 보안 정책 | https://docs.aws.amazon.com/elasticloadbalancing/latest/network/describe-ssl-policies.html |
| CloudFront 캐시 동작 | https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/distribution-web-values-specify.html |
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
# modules/edge/versions.tf
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
module "edge" {
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  ...
}
```

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
  for_each = { for dvo in aws_acm_certificate.cloudfront.domain_validation_options : dvo.domain_name => dvo }
  ...
}

resource "aws_acm_certificate_validation" "cloudfront" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for r in aws_route53_record.cloudfront_validation : r.fqdn]
}
```

`aws_acm_certificate_validation` 은 검증 완료까지 대기한다.
이 리소스를 참조하면 인증서가 준비된 뒤에 CloudFront 가 생성된다.

**와일드카드와 apex 의 검증 레코드가 동일할 수 있다.**
`for_each` 의 키를 `domain_name` 으로 두면 중복이 제거된다.

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

기존 NLB 에 리스너를 추가하는 작업이므로 재생성이 발생하지 않는다.

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

---

## Route53

| 레코드 | 타입 | 대상 |
| --- | --- | --- |
| `re-used.store` | A (alias) | CloudFront |
| `www.re-used.store` | A (alias) | CloudFront |
| `origin.re-used.store` | A (alias) | Public NLB |

**alias 레코드를 사용한다.**

| 항목 | alias | CNAME |
| --- | --- | --- |
| apex 도메인 | 가능 | **불가** |
| 조회 비용 | 무료 | 과금 |
| 조회 단계 | 1회 | 2회 |

DNS 표준상 apex 에는 CNAME 을 둘 수 없다.
Route53 alias 는 A 레코드처럼 동작하면서 AWS 리소스를 가리킬 수 있다.

CloudFront 의 Hosted Zone ID 는 고정값 `Z2FDTNDATAQYW2` 다.
NLB 는 리전마다 다르며 `aws_lb.public.zone_id` 로 참조한다.

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
| 로깅 | 비활성 |

### Price Class

| 값 | 엣지 로케이션 | 비용 |
| --- | --- | --- |
| `PriceClass_All` | 전 세계 | 높음 |
| **`PriceClass_200`** | 북미·유럽·아시아·중동·아프리카 | 중간 |
| `PriceClass_100` | 북미·유럽 | 낮음 |

한국 사용자 대상이므로 아시아 엣지가 필요하다.
`PriceClass_100` 은 아시아를 제외해 응답이 느려진다.

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

| 순서 | Path | 캐싱 | 비고 |
| --- | --- | --- | --- |
| 1 | `/api/*` | 비활성 | 동적 응답 |
| 2 | `/socket.io/*` | 비활성 | WebSocket |
| 3 | `/assets/*` | 활성 (장기) | 정적 파일 |
| — | Default (`*`) | 활성 (단기) | 프론트엔드 |

**Behavior 는 순서대로 평가된다.** 먼저 매칭되는 규칙이 적용되므로
구체적인 경로를 앞에 둔다.

#### 캐시 정책

AWS 관리형 정책을 사용한다.

| 용도 | 정책 |
| --- | --- |
| 캐싱 비활성 | `CachingDisabled` |
| 정적 파일 | `CachingOptimized` |

#### Origin Request 정책

백엔드에 전달할 헤더·쿠키·쿼리스트링을 정의한다.

| 용도 | 정책 |
| --- | --- |
| API, WebSocket | `AllViewer` — 모든 요청 정보 전달 |
| 정적 파일 | `CORS-S3Origin` 또는 없음 |

**WebSocket 은 `Upgrade` 와 `Connection` 헤더가 전달되어야 한다.**
`AllViewer` 정책이 이를 포함한다.

CloudFront 는 WebSocket 을 기본 지원하며 별도 설정이 필요 없다.

#### 허용 메서드

| Behavior | 메서드 |
| --- | --- |
| `/api/*` | GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE |
| `/socket.io/*` | 같음 |
| `/assets/*` | GET, HEAD |
| Default | GET, HEAD, OPTIONS |

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

### 관리형 룰 그룹

| 룰 그룹 | 내용 |
| --- | --- |
| `AWSManagedRulesCommonRuleSet` | OWASP 기반 공통 규칙 |
| `AWSManagedRulesKnownBadInputsRuleSet` | 알려진 악성 입력 패턴 |
| `AWSManagedRulesAmazonIpReputationList` | 평판이 낮은 IP 목록 |

AWS 가 관리하며 자동으로 갱신된다.

### Count 모드로 시작하는 이유

**Block 으로 바로 켜면 정상 요청이 차단될 수 있다.**

관리형 룰은 일반적인 공격 패턴을 기준으로 하므로,
애플리케이션의 정상 동작이 오탐으로 걸리는 경우가 있다.
파일 업로드, 긴 쿼리스트링, 특수문자를 포함한 입력 등이 대표적이다.

Count 모드는 매칭만 기록하고 요청은 통과시킨다.
실제 트래픽 패턴을 확인한 뒤 룰별로 Block 으로 전환한다.

```bash
aws wafv2 get-sampled-requests \
  --web-acl-arn <arn> \
  --rule-metric-name <name> \
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
dig origin.re-used.store +short
```

apex 와 www 는 CloudFront IP, origin 은 NLB IP 가 나온다.

### 오리진 직접 접속

CloudFront 를 거치지 않고 NLB 로 직접 확인한다.

```bash
curl -sS -o /dev/null -w "%{http_code} %{ssl_verify_result}\n" \
  https://origin.re-used.store/
```

라우트가 없으면 404 가 정상이다. `ssl_verify_result` 가 0 이면
인증서 검증에 성공한 것이다.

### CloudFront 경유

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://re-used.store/
curl -sS -o /dev/null -w "%{http_code}\n" https://www.re-used.store/

# HTTP 리다이렉트 확인
curl -sS -o /dev/null -w "%{http_code} -> %{redirect_url}\n" http://re-used.store/
```

HTTP 요청은 301 로 HTTPS 에 리다이렉트되어야 한다.

### 캐시 동작

```bash
curl -sI https://re-used.store/ | grep -i "x-cache"
```

| 값 | 의미 |
| --- | --- |
| `Miss from cloudfront` | 오리진에서 가져옴 |
| `Hit from cloudfront` | 캐시 응답 |

`/api/*` 는 캐싱을 비활성화했으므로 항상 Miss 여야 한다.

### WAF

```bash
aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1

aws cloudfront get-distribution \
  --id <distribution-id> \
  --query 'Distribution.DistributionConfig.WebACLId' \
  --output text
```

연결된 Web ACL ARN 이 출력되어야 한다.

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

**SPA 라우팅 주의** — 프론트엔드가 클라이언트 사이드 라우팅을 쓰면
`/some/path` 직접 접속 시 오리진이 404 를 반환한다.
CloudFront 커스텀 에러 응답으로 404 를 `/index.html` 200 으로
변환하는 설정이 필요할 수 있다. 프론트엔드 구현 확정 후 판단한다.