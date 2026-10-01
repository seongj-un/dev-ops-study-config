# Terraform과 provider의 버전 범위.
#   required_version "~> 1.16" : 1.16 이상 2.0 미만 (~>는 오른쪽 끝 숫자만 올라가는 것을 허용한다)
#   aws provider     "~> 6.66" : 6.66.0 이상 7.0.0 미만
# 메이저 버전(Terraform 2.0, provider 7.0)은 호환이 깨지는 변경을 담을 수 있어서 자동으로 올라가지 않게 막는다.
#
# 실제로 받는 provider의 정확한 버전과 해시는 .terraform.lock.hcl이 고정한다. 그 파일은 커밋한다(.gitignore에 넣지 않는다).
# `terraform init`은 실행한 플랫폼의 h1: 해시만 기록한다. 그래서 맥(darwin_arm64)과 리눅스(linux_amd64)에서 같은 검증이 되도록
# `terraform providers lock -platform=darwin_arm64 -platform=linux_amd64`로 두 플랫폼의 해시를 함께 넣어 두었다.
terraform {
  required_version = "~> 1.16"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
  }

  # 여기에는 backend 블록이 없다. 그러면 Terraform은 state를 이 디렉터리의 terraform.tfstate(로컬 파일)에 저장한다. 일부러 그렇게 했다.
  # 이 스택이 만드는 S3 버킷은 다른 스택(infra/aws)의 원격 state 저장소다. backend "s3"를 쓰는 스택은 `terraform init` 때 그 버킷에 접속하는데,
  # 버킷은 이 스택의 `apply`가 만들고 `init`은 `apply`보다 먼저 한다. 이 스택 자신의 state까지 그 버킷에 두면
  # "버킷이 있어야 init이 되고, init이 돼야 버킷을 만든다"는 순환이 된다(닭과 달걀 문제).
  # 그래서 이 스택만 로컬 state로 한 번 실행해 버킷을 만들고, 나머지 스택이 그 버킷을 쓴다. 로컬 state 파일은 git에 올리지 않는다(.gitignore).
}
