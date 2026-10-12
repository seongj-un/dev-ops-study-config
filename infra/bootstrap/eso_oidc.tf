# 클러스터가 스스로 발급하는 ServiceAccount 토큰으로 AWS에 들어오는 길: ESO(External Secrets Operator)용 OIDC 페더레이션.
# AWS 액세스 키를 클러스터에 넣지 않는다. github_oidc.tf와 같은 방식(AssumeRoleWithWebIdentity)인데 토큰의 발급자가 GitHub가 아니라 이 클러스터의 kube-apiserver다.
#
# 흐름은 이렇다.
#  1. k3s의 kube-apiserver가 service-account-issuer를 아래 local.oidc_issuer로 정해 두고 ServiceAccount 토큰(JWT)을 그 발급자 이름(iss)으로 서명한다.
#     ESO는 monitoring/eso-ssm ServiceAccount의 토큰(aud sts.amazonaws.com으로 투영한 것)을 STS에 내민다.
#  2. STS는 토큰의 iss로 IAM에 등록된 OIDC 공급자를 찾고, 그 발급자의 {issuer}/.well-known/openid-configuration과 거기 적힌 jwks_uri(공개 키 목록)를
#     **익명으로** 내려받아 서명을 확인한다. 클러스터는 인터넷에서 닿지 않는 곳에 있을 수 있으므로 이 두 문서를 공개 S3 버킷에 올려 둔다.
#  3. 서명이 맞고 역할 신뢰 정책의 조건(aud, sub)이 토큰의 클레임과 맞으면 STS가 그 역할의 임시 자격 증명을 준다.
#
# 이 스택(로컬 state)에 두는 이유: 발급자 URL은 버킷 이름에서 나오고, IAM 공급자와 역할 신뢰 정책에 글자 그대로 박힌다. 버킷이 infra/aws와 함께 destroy되면
# URL이 바뀌어 공급자와 신뢰 정책을 다시 만들어야 한다. 그래서 버킷·공급자·역할은 오래 남는 이 스택에 두고, 세션마다(부팅마다) 바뀌는 것은
# 객체 둘(디스커버리 문서와 JWKS)뿐이다. 새 클러스터는 새 서명 키를 만들기 때문에 인스턴스가 부팅할 때 두 객체를 다시 올린다(infra/aws의 cloud-init).

locals {
  # 발급자 URL. 아래 모든 곳에서 이 한 값을 쓴다. k3s의 service-account-issuer, 디스커버리 문서의 issuer, 토큰의 iss, IAM 공급자의 url, 신뢰 정책의 조건 키가
  # 글자 하나까지 같아야 한다. 대소문자를 구분하고, 끝 슬래시와 포트가 없어야 한다. 버킷 이름과 리전이 들어가므로 둘 중 하나가 바뀌면 URL도 바뀐다.
  # 가상 호스트 방식(버킷.s3.리전.amazonaws.com)이다. S3의 현재 기본 주소 형식이라 이 방식 하나로 정했다(경로 방식 s3.리전.amazonaws.com/버킷과 섞어 쓰면 URL이 달라진다).
  oidc_bucket = "dev-ops-study-oidc-${data.aws_caller_identity.current.account_id}"
  oidc_issuer = "https://${local.oidc_bucket}.s3.${var.region}.amazonaws.com"

  # IAM 신뢰 정책의 조건 키는 "https://"를 뗀 공급자 주소 뒤에 클레임 이름을 붙인 모양이다(<주소>:sub, <주소>:aud).
  oidc_host = trimprefix(local.oidc_issuer, "https://")

  # ESO가 읽을 수 있는 유일한 파라미터. DuckDNS 토큰(/dev-ops-study/duckdns-token)은 일부러 뺀다. 그건 인스턴스 역할만 읽는다(infra/aws/iam.tf).
  eso_discord_parameter_arn = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/dev-ops-study/discord-webhook-url"
}

# 서버 액세스 로깅은 켜지 않는다(trivy AWS-0089). state 버킷과 같은 이유다. 이 버킷에는 공개 JSON 둘뿐이고 접근 기록을 볼 일이 없다.
# 퍼블릭 액세스 차단의 두 항목을 일부러 끈다(trivy AWS-0087, AWS-0093). STS가 익명으로 읽어야 하는 버킷이라 아래 설명대로 필요하다.
# 객체 둘만 공개하고 나머지는 막혀 있다.
# 버전 관리를 켜지 않는다(trivy AWS-0090). 두 객체가 부팅마다 클러스터에서 다시 만들어지는 파생 파일이라 이력이 필요 없다(아래 설명).
#trivy:ignore:AVD-AWS-0089
#trivy:ignore:AVD-AWS-0087
#trivy:ignore:AVD-AWS-0093
#trivy:ignore:AVD-AWS-0090
resource "aws_s3_bucket" "oidc" {
  # 계정 ID를 붙이는 이유는 state_bucket.tf와 같다(이름 공간이 모든 계정에 걸쳐 하나라서 겹침을 피한다).
  bucket = local.oidc_bucket

  # false면 객체가 남아 있을 때 destroy가 버킷 삭제를 거부한다. 객체 둘은 부팅마다 다시 올라오는 것이라 잃어도 되지만,
  # 버킷이 실수로 지워지면 발급자 URL의 주인이 비어 다른 계정이 같은 이름을 가져갈 수 있다(S3 버킷 이름 선점). 지우려면 사람이 확인하게 한다.
  force_destroy = false
}

# 버전 관리는 켜지 않는다(기본값 그대로 두고 리소스도 만들지 않는다). 두 객체는 부팅마다 덮어쓰는 파생 파일이라 이력이 필요 없다.
# 옛 JWKS가 남아 있으면 오히려 옛 키로 서명한 토큰을 계속 믿게 될 수 있다.

# 저장 시 암호화: SSE-S3. state 버킷과 같은 이유다(추가 요금 없음, 코드에서 바로 읽힘). 공개 읽기와 충돌하지 않는다. S3가 읽는 요청에 투명하게 복호화해 준다.
# KMS 고객 관리형 키는 쓰지 않는다. 익명 요청은 KMS 키 권한을 가질 수 없어서 공개 객체와 함께 쓸 수 없다(trivy AWS-0132).
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 객체 소유권: BucketOwnerEnforced. ACL을 끄고 접근을 IAM과 버킷 정책으로만 정한다(state_bucket.tf와 같다).
# 아래 block_public_acls가 이미 공개 ACL을 막지만, ACL 자체를 없애서 "공개는 버킷 정책의 두 객체뿐"이라는 한 가지 길만 남긴다.
resource "aws_s3_bucket_ownership_controls" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# 퍼블릭 액세스 차단: 이 버킷은 state 버킷과 달리 일부러 공개한다. STS가 디스커버리 문서와 JWKS를 익명으로 내려받기 때문이다.
# 네 항목 가운데 정책에 관한 둘만 끈다.
#   block_public_acls       켠다. 공개 ACL은 필요 없다(소유권도 BucketOwnerEnforced라 ACL이 없다)
#   ignore_public_acls      켠다. 위와 같은 이유
#   block_public_policy     끈다. 끄지 않으면 Principal "*"를 허용하는 아래 버킷 정책을 S3가 거절한다
#   restrict_public_buckets 끈다. 켜면 공개 정책이 붙어 있어도 계정 소유자와 AWS 서비스만 접근해서 STS의 익명 읽기가 막힌다
# 가장 엄격한 설정이 이긴다. 계정 수준의 퍼블릭 액세스 차단에서 이 둘이 켜져 있으면 버킷 쪽을 꺼도 소용없으니, apply 전에 계정 설정을 확인한다(README).
resource "aws_s3_bucket_public_access_block" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

# 버킷 정책. 공개하는 것은 객체 키 둘의 s3:GetObject뿐이다.
#  - PublicReadOIDCDocuments: 디스커버리 문서(.well-known/openid-configuration)와 JWKS(openid/v1/jwks). 두 문서에는 공개 키와 발급자 주소만 있고 비밀이 없다.
#    Resource를 버킷/* 가 아니라 이 두 ARN으로 적어서 버킷에 다른 객체가 생겨도 공개되지 않는다. s3:ListBucket은 주지 않으므로 목록은 보이지 않는다.
#    쓰기는 익명에게 열리지 않는다. 객체를 올리는 것은 인스턴스 역할이다(infra/aws/iam.tf의 s3:PutObject, 같은 두 키에만).
#  - DenyInsecureTransport: TLS가 아닌 요청을 거절한다(state_bucket.tf와 같다). STS는 HTTPS로 읽는다.
resource "aws_s3_bucket_policy" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadOIDCDocuments"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource = [
          "${aws_s3_bucket.oidc.arn}/.well-known/openid-configuration",
          "${aws_s3_bucket.oidc.arn}/openid/v1/jwks",
        ]
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.oidc.arn,
          "${aws_s3_bucket.oidc.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
    ]
  })

  # 퍼블릭 액세스 차단이 끝난 뒤에 정책을 붙인다. 순서를 안 고정하면 block_public_policy가 아직 켜진 채로 정책이 들어가 거절되거나,
  # 같은 버킷 설정 호출끼리 OperationAborted로 충돌할 수 있다(state_bucket.tf 참고).
  depends_on = [aws_s3_bucket_public_access_block.oidc]
}

# 발급자 주소의 TLS 인증서 체인에서 지문(thumbprint)을 구한다. 이 값은 아래 OIDC 공급자의 thumbprint_list에만 쓰인다.
# 가상 호스트 주소(버킷.s3.리전.amazonaws.com)는 버킷에 객체가 없어도 TLS 핸드셰이크가 되므로(와일드카드 인증서) 객체를 올리기 전인 첫 apply에서도 읽힌다.
# certificates[0]은 체인에서 가장 위(루트에 가까운) 인증서다. 이 데이터 소스는 plan 때 인터넷으로 그 주소에 접속한다.
data "tls_certificate" "oidc_issuer" {
  url = local.oidc_issuer
}

# 이 클러스터의 발급자를 계정에 OIDC 공급자로 등록한다. 같은 URL의 공급자는 계정에 하나만 만들 수 있다.
#  - client_id_list(audience): 토큰의 aud가 이 목록에 있어야 STS가 받는다. ESO가 투영하는 토큰의 audience가 sts.amazonaws.com이다.
#  - thumbprint_list를 적는 이유: 비워 두면 IAM이 공급자를 만드는 순간 발급자 주소의 디스커버리 문서를 받으러 접속해 지문을 스스로 채운다(OpenIdIdpCommunicationError가 나올 수 있다).
#    그런데 이 문서는 인스턴스가 처음 부팅할 때 올리므로(infra/aws의 cloud-init 5단계) 이 스택의 첫 apply 때는 버킷에 아직 없다(익명 요청은 403).
#    AWS IAM 문서는 지문이 없으면 IdP에서 가져오고, 주면 그 값을 쓴다고 적는다(생성 시점의 접속이 실제로 생략되는지는 이 문서로 확인하지 못했다). 이 값 자체는 쓰이지 않는다. S3 주소의 JWKS는 AWS가 자기의 신뢰 루트 CA 목록으로 TLS 인증서를 검증하므로 지문이 대조되지 않는다
#    (aws provider 문서도 S3에 올린 JWKS에는 지문이 쓰이지 않는다고 적는다).
#    그래서 데이터 소스로 읽은 값을 그대로 넣는다.
#  - depends_on: 버킷과 정책이 먼저 있어야 발급자 주소가 이 계정의 실제 버킷을 가리킨다. url이 local이라 Terraform이 이 순서를 스스로 알지 못한다.
#  - 그래도 생성이 OpenIdIdpCommunicationError로 실패하면 infra/aws/up.sh를 한 번 실행해 문서가 올라간 뒤 terraform apply를 다시 한다(README 참고).
resource "aws_iam_openid_connect_provider" "cluster" {
  url             = local.oidc_issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc_issuer.certificates[0].sha1_fingerprint]

  depends_on = [aws_s3_bucket_policy.oidc]
}

# ESO가 맡는 역할. 신뢰 정책(누가 맡는가): 위 공급자가 발급자인 토큰 가운데 monitoring 네임스페이스의 eso-ssm ServiceAccount 것만.
# ESO는 ServiceAccount의 eks.amazonaws.com/role-arn 어노테이션에서 이 역할의 ARN을 읽는다(platform/external-secrets-config/serviceaccount.yaml).
resource "aws_iam_role" "eso_monitoring" {
  name = "dev-ops-study-eso-monitoring"

  # IAM 역할의 description은 라틴 문자만 받는다(github_oidc.tf 참고). 한글 설명은 이 주석에 있다.
  description = "External Secrets Operator reads the Discord webhook URL from SSM (cluster OIDC)"

  # max_session_duration은 기본값(3600초)을 그대로 쓴다. ESO는 ServiceAccount 토큰을 요청해 AssumeRoleWithWebIdentity로 임시 자격 증명을 받는다.

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ClusterServiceAccountEsoSsm"
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.cluster.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          # 두 조건은 AND다. sub는 글자 그대로 같아야 한다(StringEquals라 와일드카드도 글자로 비교된다).
          # sub 없이 aud만 두면 이 클러스터의 어느 ServiceAccount든(aud를 sts.amazonaws.com으로 투영하기만 하면) 이 역할을 맡는다.
          # aud 키는 토큰에 azp 클레임이 있으면 azp로 평가된다. Kubernetes ServiceAccount 토큰에는 azp가 없어서 aud로 평가된다.
          StringEquals = {
            "${local.oidc_host}:sub" = "system:serviceaccount:monitoring:eso-ssm"
            "${local.oidc_host}:aud" = "sts.amazonaws.com"
          }
        }
      },
    ]
  })
}

# 권한: Discord 웹훅 URL 파라미터 하나의 ssm:GetParameter뿐이다. 최소 권한이라 ReadOnlyAccess 같은 넓은 정책에 Deny를 덧대는 github_oidc.tf와 달리
# 막을 것을 따로 적을 필요가 없다(Allow에 없는 것은 기본이 거부다). GetParameters, GetParametersByPath, 다른 파라미터(DuckDNS 토큰)는 모두 거부된다.
# kms:Decrypt는 주지 않는다. SecureString이 AWS 관리형 키 alias/aws/ssm으로 암호화되어 있으면 키 정책이 같은 계정의 SSM 호출에 복호화를 허용해서
# IAM에 따로 적지 않아도 된다(Systems Manager 사용 설명서). 복호화 실패(AccessDenied에 KMS가 나오면) 그때 추가한다.
resource "aws_iam_role_policy" "eso_monitoring_ssm" {
  name = "read-discord-webhook-parameter"
  role = aws_iam_role.eso_monitoring.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDiscordWebhookParameter"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = local.eso_discord_parameter_arn
      },
    ]
  })
}
