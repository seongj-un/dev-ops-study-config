# 원격 state 저장소. 다른 스택(infra/aws)의 state 파일이 이 버킷에 저장된다.
# state를 잃으면 Terraform은 자기가 만든 리소스를 잊어서(실제 AWS 리소스는 그대로 남는다) 더는 관리하지 못하고,
# state가 새어 나가면 리소스의 모든 속성이 평문으로 보인다. 이 파일의 설정은 모두 그 둘, 곧 state를 잃지도 노출하지도 않기 위한 것이다.

# 지금 로그인한 AWS 계정의 ID. 버킷 이름에 넣는다.
data "aws_caller_identity" "current" {}

# 서버 액세스 로깅은 켜지 않는다(trivy AWS-0089). 로그를 받을 별도 버킷이 필요하고 그 버킷도 관리하고 요금을 내야 하는데,
# 이 버킷은 사용자 한 명이 Terraform으로만 쓰는 state 저장소라 객체 접근 기록을 볼 일이 없다.
#trivy:ignore:AVD-AWS-0089
resource "aws_s3_bucket" "state" {
  # S3 버킷 이름은 모든 AWS 계정이 함께 쓰는 하나의 이름 공간에서 유일해야 한다. 고정된 이름은 이미 다른 계정이 쓰고 있을 수 있어서
  # 계정 ID를 붙여 계정마다 이름이 달라지게 한다. 계정 ID는 비밀이 아니므로(콘솔과 ARN에 그대로 보인다) 남이 같은 이름을 못 만들게
  # 막아 주는 장치는 아니다. 이름이 겹쳐서 버킷 생성이 실패하는 일을 피하는 용도다.
  bucket = "dev-ops-study-tfstate-${data.aws_caller_identity.current.account_id}"

  # 기본값(false)과 같지만 일부러 적는다. false면 버킷에 객체가 남아 있을 때 `terraform destroy`가 버킷 삭제를 거부한다(S3는 빈 버킷만 지운다).
  # 이 버킷에는 state와 그 이전 버전(이력)이 들어 있다. true로 두면 destroy 한 번에 이력까지 영구 삭제되고 되돌릴 수 없다.
  # 그래서 버킷을 없앨 때는 사람이 직접 비우거나 이 값을 true로 바꾸는 확인 한 번을 거치게 한다. 절차는 README의 "정리"를 본다.
  force_destroy = false
}

# 버전 관리: 덮어쓴 이전 내용을 이전 버전으로 남긴다. Terraform은 state가 바뀔 때마다 같은 키(객체)를 통째로 덮어쓰므로,
# state를 잘못 덮어썼거나 손상됐을 때 S3에서 이전 버전을 골라 되돌릴 수 있다.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 저장 시 암호화: SSE-S3(sse_algorithm의 값 "AES256"이 SSE-S3를 뜻한다, SSE-KMS는 "aws:kms"). S3가 관리하는 키로 암호화한다.
# 추가 요금이 없고 키 권한을 따로 설정할 일도 없다. state에는 리소스의 모든 속성이 평문으로 들어 있어서 저장 시 암호화를 기본으로 둔다.
# 2023년 1월부터 새 객체는 설정이 없어도 SSE-S3로 암호화된다. 그래도 코드에 적는 이유는 두 가지다.
# 암호화 여부를 코드에서 바로 읽을 수 있고, 누가 콘솔에서 바꿔도 다음 apply가 되돌린다.
# KMS 고객 관리형 키는 키 유지비와 요청 요금이 붙는데, 이 프로젝트(계정 하나, 사용자 한 명)에서는 키 정책으로 접근을 더 나눌 일이 없어 쓰지 않았다(trivy AWS-0132).
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 퍼블릭 액세스 차단: 이 버킷이 공개될 이유는 없다. 네 가지를 모두 켠다.
#   block_public_acls       공개 ACL을 붙이는 요청을 거절한다
#   ignore_public_acls      이미 붙어 있는 공개 ACL은 무시한다
#   block_public_policy     공개 접근을 허용하는 버킷 정책을 거절한다
#   restrict_public_buckets 공개 정책이 붙어 있어도 버킷 소유 계정(과 AWS 서비스)만 접근하게 제한한다
# 2023년 4월부터 새 버킷은 기본값이 모두 차단이지만, 코드에 적어 두면 누가 콘솔에서 풀어도 다음 apply가 되돌린다.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# 객체 소유권: BucketOwnerEnforced는 ACL을 끄고 버킷 소유자가 모든 객체를 소유하게 한다. 접근은 IAM과 버킷 정책으로만 정해진다.
# ACL은 버킷과 객체마다 따로 붙는 옛 접근 제어 방식이라 권한이 정책과 ACL 두 군데로 갈라지고, AWS도 ACL을 끄는 것을 권장한다.
# 이것도 2023년 4월부터 새 버킷의 기본값이지만 코드에 적어 둔다.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# TLS(HTTPS)가 아닌 요청을 거절한다. S3 엔드포인트는 HTTPS와 HTTP를 모두 받는다.
# Terraform의 S3 백엔드는 기본이 HTTPS지만, 정책으로 막아 두면 어떤 클라이언트(AWS CLI, SDK 등)가 실수로 HTTP를 써도 state가 평문으로 오가지 않는다.
#   aws:SecureTransport는 요청이 TLS로 왔으면 true, 아니면 false다. 명시적 Deny는 어떤 Allow보다 우선하므로 권한이 있는 사용자도 HTTP로는 접근하지 못한다.
#   Resource에 버킷과 버킷/*를 모두 적는 이유: ListBucket 같은 버킷 단위 동작은 버킷 ARN에, GetObject·PutObject 같은 객체 단위 동작은 버킷/* ARN에 걸린다.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })

  # 같은 버킷의 설정을 바꾸는 호출(PutPublicAccessBlock, PutBucketPolicy)이 동시에 들어가면 S3가 간헐적으로
  # OperationAborted(충돌하는 작업이 진행 중)로 거절하는 일이 알려져 있다. Terraform은 서로 참조하지 않는 리소스를 동시에 만들기 때문에
  # 퍼블릭 액세스 차단이 끝난 뒤에 정책을 붙이도록 순서를 고정한다.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# 이전 버전을 30일 뒤에 영구 삭제한다. 현재 버전은 건드리지 않는다.
# 이전 버전이란 같은 키에 더 새로운 버전(삭제 마커 포함)이 생겨서 "현재 버전"이 아니게 된 버전이다. noncurrent_days는 이전 버전이 된 때부터 센다(만들어진 때부터가 아니다).
# 버전 관리를 켜면 apply마다 이전 state가 쌓인다. 되돌릴 일은 보통 며칠 안에 생기고, 그보다 오래된 버전은 쌓이기만 하므로 30일로 잡았다. state는 작아서 요금이 문제되는 것은 아니다.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    # 빈 filter는 "조건 없음", 곧 버킷의 모든 객체에 적용한다는 뜻이다. filter를 생략하면 지원 중단된 prefix 방식으로 처리될 수 있어서
    # (provider 스키마에서 rule의 prefix는 deprecated다) 빈 filter를 명시한다.
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  # 이전 버전을 대상으로 하는 규칙이라 버전 관리가 켜진 뒤에 붙인다.
  depends_on = [aws_s3_bucket_versioning.state]
}
