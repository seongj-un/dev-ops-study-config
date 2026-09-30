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
