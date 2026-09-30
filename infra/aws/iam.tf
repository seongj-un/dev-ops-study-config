# 인스턴스에 줄 AWS 권한: 역할(role) 하나, 그 역할에 붙는 정책 둘(SSM 에이전트용 관리형 정책 + 토큰 읽기용 인라인 정책), 그리고 역할을 인스턴스에 건네주는 인스턴스 프로파일.
# 인스턴스 역할의 권한은 인스턴스 안에서 도는 모든 프로세스가 쓸 수 있다(IMDS를 읽을 수 있는 프로세스면 누구나). 그래서 필요한 것만, 가능한 한 좁게 준다.

data "aws_caller_identity" "current" {}

# alias/aws/ssm: 기본 키로 만든 SecureString 파라미터를 암호화하는 AWS 관리형 KMS 키(aws/ssm)의 별칭. 아래 정책에서 복호화를 허용할 키를 이 키 하나로 지정하려고 조회한다.
# 이 키는 계정·리전에서 SecureString 파라미터를 기본 키로 처음 쓸 때 만들어진다. 기본 키로 SecureString을 한 번도 만든 적이 없는 계정이면 이 조회가 실패하는데,
# README는 DuckDNS 토큰 파라미터를 먼저 만들게 안내하므로 그 순서를 지키면 생겨 있다. 지키지 않았을 때의 실패가 plan 단계에서 드러나는 것은 오히려 낫다
# (인스턴스가 떠서 토큰을 못 읽고 나서야 알게 되는 것보다 빠르고 싸다).
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

# 신뢰 정책(누가 이 역할을 맡을 수 있는가): EC2 서비스만. 인스턴스가 시작될 때 EC2가 이 역할을 맡아 임시 자격 증명을 인스턴스 메타데이터(IMDS)에 넣어 준다.
resource "aws_iam_role" "k3s" {
  name = "${local.project}-k3s"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
    ]
  })
}

# AmazonSSMManagedInstanceCore(AWS 관리형 정책): SSM 에이전트가 SSM 서비스와 통신하는 데 필요한 권한이다. 이것이 있어야 인스턴스가 Systems Manager에 등록되어
# Session Manager로 셸을 열고(SSH 대신) Run Command(send-command)로 명령을 받을 수 있다.
# 이 정책에는 Parameter Store의 값을 읽는 권한이 없다. 읽기 권한은 아래에 따로 준다.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.k3s.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# DuckDNS 토큰을 읽는 인라인 정책. 인라인 정책은 이 역할에만 속해서 다른 주체에 붙일 수 없고, 역할과 함께 만들어지고 지워진다.
# 토큰은 user_data나 Terraform 변수에 넣지 않는다. user_data는 암호화되지 않아서 인스턴스 호스트의 모든 프로세스(IMDS)와 EC2 API로 조회할 권한이 있는 누구나 평문으로 읽을 수 있다.
# 그래서 토큰은 SSM Parameter Store에만 두고, 인스턴스가 부팅 때 이 역할로 직접 읽는다.
#
# 최소 권한으로 딱 둘만 허용한다:
#  1. ssm:GetParameter를 파라미터 하나의 ARN에만. ssm:*나 GetParametersByPath(경로 아래 여러 개 읽기)는 주지 않고 Resource도 "*"가 아니다.
#     ARN은 arn:aws:ssm:<리전>:<계정 ID>:parameter<이름> 형식이다. 이름이 /로 시작하므로(variables.tf에서 강제한다) 이어 붙이면 parameter/dev-ops-study/... 가 된다.
#  2. kms:Decrypt를 (a) aws/ssm 키 하나에만, (b) kms:ViaService 조건으로 SSM이 대신 호출할 때만. SecureString은 KMS로 암호화되어 있어서 값을 읽을 때 복호화가 필요하다.
#     조건 덕분에 이 역할로 KMS API를 직접 호출해 임의의 데이터를 복호화할 수는 없고, SSM을 거친 복호화만 된다. 그 SSM 호출은 위 1번에서 허용한 파라미터 하나로만 갈 수 있다.
#     참고로 AWS 관리형 키의 키 정책은 같은 계정의 주체가 SSM을 거쳐 쓰는 것을 이미 허용한다. 이 문장은 그 범위를 넘지 않고, 이 역할에 필요한 복호화가 무엇이고 어디까지인지를
#     역할의 정책만 읽어도 보이게 적어 두는 것이다. 파라미터를 고객 관리형 키로 바꾸면 Resource를 그 키의 ARN으로 바꾸고, 키 정책이 이 역할의 사용을 막지 않는지도 확인한다.
resource "aws_iam_role_policy" "duckdns_token" {
  name = "read-duckdns-token"
  role = aws_iam_role.k3s.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDuckdnsTokenParameter"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.duckdns_token_parameter}"
      },
      {
        Sid      = "DecryptViaSsmOnly"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = data.aws_kms_alias.ssm.target_key_arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.region}.amazonaws.com"
          }
        }
      },
    ]
  })
}

# 인스턴스 프로파일: EC2 인스턴스에 IAM 역할을 붙일 때 쓰는 그릇이다. 인스턴스는 역할을 직접 받지 못하고 프로파일을 통해 받는다
# (콘솔에서 EC2 역할을 만들면 같은 이름의 프로파일이 자동으로 함께 만들어지지만 Terraform은 명시적으로 만들어야 한다).
resource "aws_iam_instance_profile" "k3s" {
  name = aws_iam_role.k3s.name
  role = aws_iam_role.k3s.name
}
