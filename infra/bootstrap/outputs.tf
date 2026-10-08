output "state_bucket" {
  description = "원격 state를 저장하는 S3 버킷 이름"
  value       = aws_s3_bucket.state.bucket
}

output "region" {
  description = "state 버킷이 있는 리전. infra/aws의 backend region과 같아야 한다"
  value       = aws_s3_bucket.state.bucket_region
}

# infra/aws의 `terraform init`에 붙이는 인자다. backend 블록에는 변수·local·data 같은 참조를 쓸 수 없어서("Variables may not be used here")
# 계정 ID가 들어가는 버킷 이름을 그 스택의 코드에 미리 적을 수 없다. 그래서 그 스택은 버킷만 비워 두고(부분 설정, partial configuration) init할 때 이 값을 넘긴다.
# 값에 따옴표를 넣지 않았다. `$(terraform output -raw ...)`로 끼워 넣으면 결과 속의 따옴표는 셸이 벗겨 주지 않고 글자 그대로 Terraform에 넘어가서
# `Invalid backend configuration argument` 오류가 난다. 버킷 이름에는 공백이나 특수문자가 없어서 따옴표 없이도 한 단어다.
output "backend_config_arg" {
  description = "infra/aws의 terraform init에 붙일 -backend-config 인자(버킷 이름)"
  value       = "-backend-config=bucket=${aws_s3_bucket.state.bucket}"
}

# 저장소 변수 AWS_PLAN_ROLE_ARN에 넣는 값이다(infra/aws/README의 "GitHub Actions에서 plan"). ARN에는 계정 ID가 들어 있지만 비밀은 아니다.
# 이 ARN을 안다고 역할을 맡을 수 있는 것이 아니다. 맡으려면 신뢰 정책의 sub에 맞는 GitHub OIDC 토큰이 있어야 한다.
output "github_plan_role_arn" {
  description = "GitHub Actions의 terraform-plan 워크플로가 맡는 역할의 ARN(저장소 변수 AWS_PLAN_ROLE_ARN)"
  value       = aws_iam_role.github_plan.arn
}
