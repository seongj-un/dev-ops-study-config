provider "aws" {
  region = var.region

  # 이 스택이 만드는 리소스 가운데 태그를 붙일 수 있는 것(버킷, 예산, OIDC 공급자, IAM 역할)에 모두 붙는다. 리소스마다 tags를 적지 않아도 되어서 빠뜨릴 일이 없다.
  # 버전 관리·암호화 같은 버킷 설정 리소스와 정책 연결·인라인 정책은 태그를 붙일 수 없는 리소스라서 해당하지 않는다.
  default_tags {
    tags = {
      Project   = "dev-ops-study"
      ManagedBy = "terraform"
    }
  }
}
