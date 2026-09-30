locals {
  project = "dev-ops-study"

  # 모든 리소스에 붙일 태그. 아래 default_tags가 프로바이더 수준에서 붙이고, ec2.tf의 루트 볼륨에는 같은 값을 volume_tags로 따로 붙인다.
  tags = {
    Project   = local.project
    ManagedBy = "terraform"
  }
}

provider "aws" {
  region = var.region

  # default_tags: 이 프로바이더로 만드는 리소스(태그를 지원하는 것)에 태그를 자동으로 붙인다. 리소스마다 tags를 반복해 적지 않아도 빠뜨리는 리소스가 없다.
  # 붙이는 이유:
  #  - 비용: Project 태그를 Billing 콘솔에서 비용 할당 태그로 활성화하면 Cost Explorer에서 이 실습의 비용만 걸러 볼 수 있다(활성화는 따로 해야 하고 반영에 시간이 걸린다).
  #  - 정리: destroy 뒤에 Project=dev-ops-study 태그로 검색(Resource Groups의 Tag Editor)하면 남아서 과금되는 리소스가 있는지 확인할 수 있다.
  #  - 소유: ManagedBy=terraform이 붙은 리소스는 콘솔에서 손으로 고치지 않는다는 표시다(손으로 고치면 다음 plan에서 되돌려진다).
  default_tags {
    tags = local.tags
  }
}
