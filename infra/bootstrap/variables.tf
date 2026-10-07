# S3 버킷을 만들 리전(서울). 예산(Budgets)은 리전이 없는 전역 서비스라서 이 값과 무관하다.
# 버킷의 리전은 만든 뒤에 바꿀 수 없으므로 apply한 뒤에는 이 값을 바꾸지 않는다.
# infra/aws의 backend "s3"에 적는 region도 이 값과 같아야 한다(그 스택이 버킷을 찾아가는 주소의 일부다).
variable "region" {
  description = "S3 state 버킷을 만들 AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

# 기본값에 실제 주소를 적은 이유: 이 주소는 커밋 작성자 이메일로 이미 이 저장소의 git 이력에 공개되어 있어서, 코드에 적어도 새로 드러나는 정보가 없다.
# 다른 주소로 받고 싶으면 기본값을 고치지 말고 `-var alert_email=...`이나 *.tfvars로 덮어쓴다(*.tfvars는 .gitignore가 제외한다).
variable "alert_email" {
  description = "예산 알림을 받을 이메일 주소"
  type        = string
  default     = "seongjun154@naver.com"
}

variable "budget_limit_usd" {
  description = "월 예산 한도(USD). 이 금액의 50%와 100%에서 실제 사용액 알림을, 100%에서 예측 알림을 보낸다"
  type        = number
  default     = 20

  validation {
    condition     = var.budget_limit_usd > 0
    error_message = "budget_limit_usd는 0보다 커야 한다."
  }
}

variable "early_warning_limit_usd" {
  description = "조기 경보용 월 예산 한도(USD). 이번 달 실제 사용액이 이 금액을 넘으면 알린다"
  type        = number
  default     = 5

  validation {
    condition     = var.early_warning_limit_usd > 0
    error_message = "early_warning_limit_usd는 0보다 커야 한다."
  }

  validation {
    condition     = var.early_warning_limit_usd < var.budget_limit_usd
    error_message = "early_warning_limit_usd는 budget_limit_usd보다 작아야 한다(조기 경보가 본 예산보다 먼저 울려야 한다)."
  }
}

# GitHub Actions OIDC 토큰의 sub 클레임 앞부분. github_oidc.tf의 신뢰 정책이 이 뒤에 ":pull_request"와 ":ref:refs/heads/main"을 붙여 비교한다.
# 형식이 "repo:<소유자>@<소유자 ID>/<저장소>@<저장소 ID>"인 이유: 2026-07-15 이후에 만든 저장소는 sub에 이름 말고도 바뀌지 않는 숫자 ID가 들어간다(immutable subject).
# 이름만 쓰던 예전 형식(repo:seongj-un/dev-ops-study-config)은 저장소나 계정 이름이 지워지고 다른 사람이 같은 이름을 가져가면 그 사람의 토큰도 같은 sub가 된다.
# 이 저장소는 2026-09-30에 만들어져서 새 형식이고, 예전 형식으로 적으면 AssumeRoleWithWebIdentity가 "Not authorized"로 실패한다.
# 값 확인: gh api repos/seongj-un/dev-ops-study-config/actions/oidc/customization/sub --jq .sub_claim_prefix
# 저장소 이름을 바꾸거나 옮기면 이 값도 바뀐다(ID는 그대로지만 이름 부분이 바뀐다). 그때 이 값을 고쳐 apply한다.
variable "github_oidc_sub_prefix" {
  description = "GitHub Actions OIDC 토큰 sub 클레임의 저장소 접두사(repo:<소유자>@<ID>/<저장소>@<ID>)"
  type        = string
  default     = "repo:seongj-un@173442979/dev-ops-study-config@1397588081"

  # 신뢰 정책은 StringEquals라서 와일드카드가 글자로 비교되지만, 실수로 *를 넣어 넓히려는 시도나 예전 이름 형식이 들어오는 것을 apply 전에 막는다.
  validation {
    condition     = can(regex("^repo:[A-Za-z0-9-]+@[0-9]+/[A-Za-z0-9._-]+@[0-9]+$", var.github_oidc_sub_prefix))
    error_message = "github_oidc_sub_prefix는 repo:<소유자>@<소유자 ID>/<저장소>@<저장소 ID> 형식이어야 한다(와일드카드 없이)."
  }
}
