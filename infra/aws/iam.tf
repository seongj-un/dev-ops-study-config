# 인스턴스에 줄 AWS 권한: 역할(role) 하나, 그 역할에 붙는 정책 둘(SSM 에이전트용 관리형 정책 + 파라미터 읽기용 인라인 정책), 그리고 역할을 인스턴스에 건네주는 인스턴스 프로파일.
# 인스턴스 역할의 권한은 인스턴스 안에서 도는 모든 프로세스가 쓸 수 있다(IMDS를 읽을 수 있는 프로세스면 누구나). 그래서 필요한 것만, 가능한 한 좁게 준다.

data "aws_caller_identity" "current" {}

# alias/aws/ssm: 기본 키로 만든 SecureString 파라미터를 암호화하는 AWS 관리형 KMS 키(aws/ssm)의 별칭. 아래 정책에서 복호화를 허용할 키를 이 키 하나로 지정하려고 조회한다.
# 이 키는 계정·리전에서 처음 쓰일 때 만들어진다. 아직 없어도 plan은 실패하지 않는다: 이 데이터 소스는 별칭으로 DescribeKey를 부르는데,
# AWS가 미리 정해 둔 별칭(alias/aws/...)에 DescribeKey를 부르면 KMS가 그때 AWS 관리형 키를 만들어 별칭에 잇는다(AWS 관리형 키는 월 요금이 없다).
# 반대로 DuckDNS 토큰이나 Discord 웹훅 URL 파라미터가 없거나 이름·리전이 틀려도 plan은 모른다(아래 ARN은 문자열을 이어 붙일 뿐 파라미터를 읽지 않는다).
# 그 실수는 부팅 뒤 /var/log/devops-bootstrap.log의 "경고: DuckDNS 갱신 실패"나 "경고: Discord 웹훅 URL을 SSM에서 읽지 못했다"로만 드러나므로,
# apply 전에 README의 describe-parameters로 확인한다.
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

locals {
  # 인스턴스가 읽는 SSM 파라미터 둘의 ARN: arn:aws:ssm:<리전>:<계정 ID>:parameter<이름>. 이름이 /로 시작하므로(variables.tf에서 강제한다) 이어 붙이면 parameter/dev-ops-study/... 가 된다.
  #  - DuckDNS 토큰: duckdns-update가 읽는다(부트스트랩 3단계에서 한 번, 그 뒤 타이머가 5분마다).
  #  - Discord 웹훅 URL: 부트스트랩 7단계가 읽어 monitoring/alertmanager-discord Secret으로 만든다.
  duckdns_token_parameter_arn   = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.duckdns_token_parameter}"
  discord_webhook_parameter_arn = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.discord_webhook_parameter}"

  # 이 역할이 읽을 수 있는 파라미터는 정확히 이 둘이다. 아래 정책의 허용(Resource)과 거부(NotResource)가 같은 목록을 쓰므로 한쪽만 고쳐서 어긋나는 일이 없다.
  readable_parameter_arns = [local.duckdns_token_parameter_arn, local.discord_webhook_parameter_arn]
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
# 주의: 이 정책은 ssm:GetParameter와 ssm:GetParameters도 Resource "*"(모든 파라미터)에 허용한다. 그대로 두면 이 역할이 계정의 모든 파라미터를
# 읽을 수 있어서, 아래 인라인 정책의 명시적 Deny로 위 파라미터 둘(DuckDNS 토큰, Discord 웹훅 URL)만 남기고 막는다.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.k3s.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 파라미터 둘(DuckDNS 토큰, Discord 웹훅 URL)을 읽는 인라인 정책. 인라인 정책은 이 역할에만 속해서 다른 주체에 붙일 수 없고, 역할과 함께 만들어지고 지워진다.
# 리소스 이름(duckdns_token)과 정책 이름(read-duckdns-token)은 토큰 하나만 읽던 때의 것이다. 정책 이름은 바꿀 수 없는 속성이라(바꾸면 정책을 지우고 새로 만든다) 그대로 둔다.
# 두 값은 user_data나 Terraform 변수에 넣지 않는다. user_data는 암호화되지 않아서 인스턴스 호스트의 모든 프로세스(IMDS)와 EC2 API로 조회할 권한이 있는 누구나 평문으로 읽을 수 있다.
# 그래서 SSM Parameter Store에만 두고, 인스턴스가 부팅 때 이 역할로 직접 읽는다.
#
# 문장은 셋이다:
#  1. 허용(ReadBootstrapParameters): ssm:GetParameter를 파라미터 둘의 ARN에만(local.readable_parameter_arns).
#  2. 거부(DenyOtherParameters): 파라미터 값을 돌려주는 API 넷(GetParameter, GetParameters, GetParametersByPath, GetParameterHistory)을
#     그 둘이 아닌 모든 리소스(NotResource, 1번과 같은 목록)에 대해 막는다. 필요한 이유는 둘이 겹쳐서다:
#     (a) 위 AmazonSSMManagedInstanceCore가 GetParameter(s)를 Resource "*"로 허용하고, (b) aws/ssm 키의 키 정책이 같은 계정의 모든 주체에게
#     SSM을 거친 복호화를 허용한다. 둘이 겹치면 이 역할(곧 IMDS에 닿는 인스턴스의 모든 프로세스)이 계정의 다른 파라미터와 SecureString까지 읽는다.
#     명시적 Deny는 어느 정책의 Allow보다 우선하므로, 관리형 정책을 그대로 붙여도 읽을 수 있는 것은 그 둘뿐이다.
#     GetParametersByPath와 GetParameterHistory는 지금 어느 정책도 허용하지 않지만 값을 돌려주는 API라서, 나중에 붙는 정책이 읽기를 다시 열지 못하게 함께 막는다.
#     Session Manager 셸과 Run Command(AWS-RunShellScript)는 파라미터를 읽지 않으므로 이 Deny와 무관하다.
#  3. 허용: kms:Decrypt를 (a) aws/ssm 키 하나에만, (b) kms:ViaService 조건으로 SSM이 대신 호출할 때만. SecureString은 KMS로 암호화되어 있어서 값을 읽을 때 복호화가 필요하다.
#     사실 이 문장이 없어도 복호화는 된다(위 (b)의 키 정책). 복호화 범위를 실제로 좁히는 것은 2번이다: SSM은 이 역할이 읽도록 허용된 파라미터를
#     읽을 때만 복호화를 대신 부른다. 이 문장은 이 역할에 필요한 복호화가 무엇인지를 역할의 정책만 읽어도 보이게 적어 두는 것이다.
#     이 문장이 허용하는 키는 aws/ssm 하나라서, 파라미터 둘은 모두 기본 키로 만든 SecureString이어야 한다. 파라미터를 고객 관리형 키로 바꾸면 Resource를 그 키의 ARN으로 바꾸고, 키 정책이 이 역할의 사용을 허용하는지도 확인한다.
resource "aws_iam_role_policy" "duckdns_token" {
  name = "read-duckdns-token"
  role = aws_iam_role.k3s.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadBootstrapParameters"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = local.readable_parameter_arns
      },
      {
        Sid         = "DenyOtherParameters"
        Effect      = "Deny"
        Action      = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"]
        NotResource = local.readable_parameter_arns
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
