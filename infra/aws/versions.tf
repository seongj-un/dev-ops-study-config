# 이 스택(infra/aws)이 요구하는 Terraform 본체와 프로바이더의 버전 범위.
# 범위는 "이 버전대에서는 같은 동작을 기대한다"는 약속이고, 실제로 어느 버전이 쓰이는지는 .terraform.lock.hcl이 정확히 고정한다.

terraform {
  # ~> 1.16은 "1.16 이상, 2.0 미만"이다. ~>는 적은 숫자 가운데 맨 끝 자리만 올라가는 것을 허용한다(~> 1.16.0이면 1.16.x만 허용).
  # 하한을 1.16으로 둔 것은 이 코드를 검증한 버전대(1.16.4)이기 때문이다. backend.tf의 use_lockfile은 1.10부터 있다.
  required_version = "~> 1.16"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # ~> 6.66은 "6.66 이상, 7.0 미만"이다. 호환이 깨질 수 있는 변경은 메이저 버전(7.0)에서만 넣는다는 관례라서, 마이너 업데이트는 받고 메이저는 막는다.
      # 정확한 버전과 패키지 해시는 .terraform.lock.hcl에 있다. 그 파일을 커밋해 두면 다른 PC와 CI에서도 같은 바이너리를 받는다.
      # 버전을 올릴 때는 terraform init -upgrade를 하고 잠금 파일의 diff를 검토한다.
      version = "~> 6.66"
    }
  }
}
