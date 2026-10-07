# GitHub Actions가 AWS에 들어오는 길: OIDC 페더레이션. AWS 액세스 키(오래 사는 자격 증명)를 GitHub 시크릿에 넣지 않는다.
#
# 잡 하나마다 이렇게 된다.
#  1. 잡이 GitHub의 OIDC 발급자(https://token.actions.githubusercontent.com)에게서 ID 토큰(JWT)을 받는다. 워크플로에 permissions의 id-token: write가 있어야 받을 수 있다.
#     토큰에는 "어느 저장소의, 어느 이벤트·ref에서 도는 잡인가"가 클레임(sub, aud 등)으로 들어 있고 GitHub의 키로 서명되어 있다. 토큰은 발급 후 몇 분이면 만료된다.
#  2. aws-actions/configure-aws-credentials가 그 토큰으로 STS의 AssumeRoleWithWebIdentity를 부른다. STS는 아래 OIDC 공급자에 등록된 발급자의 공개 키(JWKS)로
#     서명을 확인하고, 역할의 신뢰 정책 조건(aud, sub)이 토큰의 클레임과 맞는지 본다.
#  3. 맞으면 STS가 이 역할의 임시 자격 증명(최대 1시간)을 돌려준다. 잡마다 새로 받고, 만료되면 쓸 수 없다.
# 그래서 새어 나갈 오래된 비밀이 없다. 저장소에는 AWS 키가 없고, 받은 자격 증명은 짧게 살며, 어느 저장소·이벤트가 받을 수 있는지는 AWS 쪽 신뢰 정책이 정한다.
#
# 이 스택(로컬 state)에 두는 이유: 역할은 infra/aws의 plan을 돌리는 데 쓰는데, infra/aws 안에 두면 그 스택을 destroy할 때 역할도 사라지고
# 역할을 바꾸는 PR의 plan을 그 역할 자신이 돌리게 된다. 상태 버킷처럼 "다른 스택보다 먼저 있고 오래 남는 것"이라 여기에 둔다.

# 계정에 GitHub의 OIDC 발급자를 등록한다. 같은 URL의 공급자는 계정에 하나만 만들 수 있다(이미 있으면 apply가 EntityAlreadyExists로 실패하므로 import한다).
#  - client_id_list(audience): 토큰의 aud가 이 목록에 있어야 STS가 받는다. configure-aws-credentials가 토큰을 요청할 때 쓰는 기본 audience가 sts.amazonaws.com이다.
#  - thumbprint_list는 적지 않는다. aws provider 6.x에서 선택 인자(Optional + Computed)라서, 비우면 IAM이 발급자 서버 인증서의 최상위 중간 CA 지문을 스스로 받아 채운다.
#    게다가 GitHub에는 이 지문이 검증에 쓰이지 않는다. AWS는 JWKS 엔드포인트의 TLS 인증서를 자기의 신뢰 루트 CA 목록으로 검증하고, 그 목록에 없는 CA를 쓰는 발급자이거나
#    인증서를 받지 못하는 경우에만 지문으로 검증한다(IAM 사용 설명서 "Create an OpenID Connect (OIDC) identity provider in IAM"). 예전 안내서가 GitHub의 지문을
#    직접 적으라고 했던 것은 이 방식으로 바뀌기 전의 일이고, configure-aws-credentials의 README도 지금은 "지정해도 무시된다"고 적는다.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  # 이 역할을 맡을 수 있는 토큰의 sub 값 둘. StringEquals라서 글자 그대로 같아야 하고, 와일드카드(*, ?)도 글자로 비교된다.
  #  - pull_request: 이 저장소에서 연 PR의 실행. terraform-plan 워크플로가 PR마다 plan을 만든다.
  #  - ref:refs/heads/main: main 브랜치에서 도는 실행. 같은 워크플로를 main에서 손으로 돌리는 drift 검사(workflow_dispatch)가 이 값으로 들어온다.
  #    main을 믿어도 넓어지는 것이 거의 없다. main에 코드를 넣을 수 있는 주체(PR 머지, 룰셋을 우회하는 앱 저장소 CI의 deploy key)는
  #    이미 ArgoCD를 통해 클러스터에 무엇이든 배포할 수 있다. 이 역할이 주는 것은 그보다 훨씬 작은 AWS 읽기다.
  #    다른 브랜치(ref:refs/heads/<이름>)는 받지 않는다. 쓰기 권한이 있는 사람이나 deploy key는 리뷰 없이 브랜치를 만들 수 있고, 그 브랜치의 워크플로를
  #    push나 workflow_dispatch로 바로 돌릴 수 있기 때문이다.
  #
  # 왜 *가 아닌가(예: StringLike로 "<접두사>:*", "repo:seongj-un/*", 또는 sub 조건 없이 aud만):
  #  - OIDC 공급자는 GitHub 전체가 쓰는 발급자 하나다. aud sts.amazonaws.com도 configure-aws-credentials를 쓰는 모든 저장소의 기본값이다.
  #    sub 조건이 없거나 넓으면 세상의 어느 GitHub 저장소의 워크플로든(또는 이 저장소의 아무 브랜치·태그든) 이 역할을 맡을 수 있다.
  #    2023년에 여러 회사에서 실제로 발견된 잘못된 설정이 이것이다(신뢰 정책에 sub 조건이 없었다).
  #  - "<접두사>:*"는 이 저장소 안으로 좁히지만 리뷰를 거치지 않은 모든 브랜치·태그·환경을 함께 믿는다(위). 필요한 두 값만 정확히 적는다.
  # pull_request는 같은 저장소의 PR과 포크에서 온 PR을 구별하지 않는다(둘 다 이 값이다). 포크 PR이 이 역할을 못 맡는 것은 GitHub가 포크 PR의 실행에
  # OIDC 토큰을 발급하지 않기 때문이고, 워크플로도 포크 PR에서는 잡을 건너뛴다. pull_request_target(기본 브랜치의 권한·시크릿으로 돌아서 포크의 코드를 체크아웃하면 위험하다)은 쓰지 않는다.
  # PR의 실행은 PR 브랜치에 있는 워크플로 파일로 돈다. 곧 이 저장소에 브랜치를 올려 PR을 열 수 있는 사람은 이 역할로 아무 코드나 돌릴 수 있다.
  # 그래서 이 역할은 읽기만 하고, 비밀과 state 쓰기는 아래 Deny로 막는다.
  github_plan_subjects = [
    "${var.github_oidc_sub_prefix}:pull_request",
    "${var.github_oidc_sub_prefix}:ref:refs/heads/main",
  ]
}

# terraform plan 전용 역할. 신뢰 정책(누가 이 역할을 맡는가): 위 OIDC 공급자가 발급한 토큰 가운데 aud와 sub가 맞는 것만.
resource "aws_iam_role" "github_plan" {
  name = "dev-ops-study-github-plan"

  # IAM 역할의 description은 라틴 문자(ASCII와 Latin-1)만 받는다. 한글 설명은 이 주석에 있다.
  description = "GitHub Actions terraform plan for infra/aws (OIDC, read-only)"

  # 이 역할로 받는 자격 증명의 최대 수명. 3600초(1시간)는 IAM이 허용하는 가장 작은 최대값이다(기본값과 같지만 의도를 드러내려고 적는다).
  # 워크플로는 이보다 짧게(role-duration-seconds) 요청한다. plan은 몇 분이면 끝난다.
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "GitHubActionsPlan"
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          # 두 조건은 AND다. 값이 목록이면 그 안에서는 OR다(sub가 둘 중 하나와 같으면 된다).
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = local.github_plan_subjects
          }
        }
      },
    ]
  })
}

# ReadOnlyAccess(AWS 관리형 정책): 거의 모든 서비스의 Describe*·Get*·List*를 모든 리소스에 허용한다. plan이 하는 일은 모두 읽기라서 이것으로 충분하다.
#  - S3 백엔드: state 객체 읽기(s3:GetObject)와 버킷 목록(s3:ListBucket). 워크플로가 -lock=false로 돌려서 잠금 객체를 만들지 않고, plan은 state를 쓰지 않는다.
#  - refresh와 data 소스: ec2:Describe*(VPC, 서브넷, 라우트 테이블, 보안 그룹·규칙, 인스턴스와 그 속성, 볼륨, 태그, AMI, 인스턴스 유형, 네트워크 ACL),
#    iam:GetRole·GetRolePolicy·ListRolePolicies·ListAttachedRolePolicies·GetInstanceProfile, kms:ListAliases·DescribeKey(alias/aws/ssm),
#    ssm:GetParameter(Canonical의 공개 AMI 파라미터), sts:GetCallerIdentity. CloudTrail 이벤트 기록(2026-09-28~10-06)에 남은 infra/aws의 Terraform 읽기 호출이
#    정확히 이것들이고 모두 ReadOnlyAccess에 들어 있다(S3 객체 읽기는 데이터 이벤트라서 이벤트 기록에 남지 않는다).
# 대가: 넓다. 이 계정의 거의 모든 메타데이터(리소스 목록, 정책, 태그)와 S3 객체를 읽을 수 있다. 계정에 이 실습 말고 다른 것이 없어서 받아들이고,
# 아래 Deny로 이 계정에서 실제로 비밀을 돌려주는 읽기만 골라 막는다. 서비스가 늘어 비밀을 담는 곳이 생기면 Deny를 함께 늘린다.
resource "aws_iam_role_policy_attachment" "github_plan_readonly" {
  role       = aws_iam_role.github_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# 명시적 Deny는 어느 정책의 Allow보다 우선한다. ReadOnlyAccess가 허용하는 것 가운데 막을 것을 적는다.
#  1. DenyProjectParameters: 이 프로젝트의 SSM 파라미터(/dev-ops-study/ 아래의 DuckDNS 토큰, Discord 웹훅 URL) 값을 돌려주는 API(GetParameter, GetParameters,
#     GetParameterHistory 등 ssm:GetParameter*). ReadOnlyAccess에는 ssm:Get*가 있고, aws/ssm 키의 키 정책은 같은 계정의 모든 주체에게 SSM을 거친 복호화를
#     허용하므로(infra/aws/iam.tf의 설명) 막지 않으면 SecureString도 평문으로 읽힌다. 리전을 *로 둔 것은 어느 리전에 만들어도 막으려는 것이다.
#     plan이 읽는 파라미터(/aws/service/canonical/...)는 AWS의 공개 파라미터라 이 경로에 걸리지 않는다.
#  2. DenyParametersByPath: GetParametersByPath는 모든 리소스에 막는다. 이 API는 요청한 경로(예: / 또는 /dev-ops-study)의 ARN으로 권한을 보고, 재귀(Recursive)로 부르면
#     그 아래 모든 단계의 값을 돌려준다. 그래서 1번처럼 하위 파라미터만 거부해도 상위 경로로 읽을 수 있다(Systems Manager 사용 설명서의 Parameter Store 접근 제한 문서에
#     이 주의가 있다). plan은 이 API를 쓰지 않는다.
#  3. DenyCommandOutput: Run Command의 실행 결과(GetCommandInvocation, ListCommandInvocations). infra/aws/README의 방법으로 kubeconfig(cluster-admin의 클라이언트 키)를
#     받으면 그 출력이 SSM 명령 기록에 약 30일 남는다(infra/aws/outputs.tf). ReadOnlyAccess의 ssm:Get*·ssm:List*로 그것을 읽을 수 있어서 막는다.
#  4. DenyObjectWrites: S3 객체 쓰기와 삭제. ReadOnlyAccess에는 원래 없지만, 나중에 누가 쓰기 정책을 붙이더라도 CI가 state(aws/terraform.tfstate)나
#     잠금 객체(.tflock)를 쓰거나 지우지 못하게 못 박는다. 워크플로에서 -lock=false를 빠뜨리면 잠금 객체를 만들다 AccessDenied로 실패하므로 그 실수도 드러난다.
#     DeleteObjectVersion까지 막는 이유: 버전 관리가 켜진 버킷에서 DeleteObject는 삭제 마커만 더하지만, DeleteObjectVersion은 이전 버전(state 이력)을 영구히 지운다.
resource "aws_iam_role_policy" "github_plan_deny" {
  name = "deny-secrets-and-writes"
  role = aws_iam_role.github_plan.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyProjectParameters"
        Effect   = "Deny"
        Action   = "ssm:GetParameter*"
        Resource = "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/dev-ops-study/*"
      },
      {
        Sid      = "DenyParametersByPath"
        Effect   = "Deny"
        Action   = "ssm:GetParametersByPath"
        Resource = "*"
      },
      {
        Sid      = "DenyCommandOutput"
        Effect   = "Deny"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      },
      {
        Sid      = "DenyObjectWrites"
        Effect   = "Deny"
        Action   = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = "*"
      },
    ]
  })
}
