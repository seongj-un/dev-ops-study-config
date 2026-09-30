# 상태(state) 파일을 S3에 둔다. 상태는 "Terraform이 무엇을 만들었는지"의 기록이다. 잃어버리면 Terraform이 자기가 만든 리소스를 모르게 되어
# destroy로 지울 수 없고, AWS에 남은 리소스는 계속 과금된다. 로컬 디스크에 두면 PC가 바뀌거나 디스크가 날아갈 때 그 기록이 함께 사라지므로,
# 부트스트랩 스택(infra/bootstrap)이 만든 버킷(버전 관리 켜짐)에 둔다.
#
# 이 블록에는 bucket이 없다(부분 구성, partial configuration). init 때 넘긴다:
#   terraform init -backend-config="bucket=dev-ops-study-tfstate-<계정 ID>"
# 이유: (1) 버킷 이름에 AWS 계정 ID가 들어가서, 이 값을 저장소에 적으면 저장소가 특정 계정에 묶인다. (2) 백엔드 블록에는 변수나 locals를 쓸 수 없어서
# 값을 코드 안에서 계산할 방법이 없다. 그래서 고정할 수 있는 값(key, region 등)만 여기 적고 계정마다 다른 값은 init 인자로 채운다.
# 백엔드도 프로바이더와 같은 AWS 자격 증명(aws login 등)을 쓴다.
terraform {
  backend "s3" {
    # 버킷 안에서 이 스택의 상태가 놓이는 경로. aws/ 접두사가 이 스택의 자리다.
    key = "aws/terraform.tfstate"

    # 상태 버킷이 있는 리전이다. 백엔드는 변수를 읽을 수 없어서 var.region을 못 쓰고 값을 그대로 적는다.
    # 리소스를 만드는 리전(variables.tf의 var.region)과는 별개의 설정이라 서로 같을 필요는 없다.
    region = "ap-northeast-2"

    # S3 자체 잠금: 상태 객체 옆에 잠금 객체(aws/terraform.tfstate.tflock)를 S3의 조건부 쓰기로 만들어서, apply가 동시에 둘 돌아 상태를 덮어쓰는 것을 막는다.
    # DynamoDB 잠금 테이블이 필요 없어서 관리할 리소스와 요금이 하나 줄어든다(Terraform 1.10부터. dynamodb_table 방식은 더 이상 권장되지 않는다).
    use_lockfile = true

    # 상태 객체를 저장할 때 서버 측 암호화를 요청한다. 상태에는 리소스의 속성 값(IAM 정책, 주소, ID, user_data_base64로 넘긴 cloud-init 전체 등)이 그대로 들어 있다.
    # 이 스택은 비밀 값을 만들거나 넣지 않도록 설계했지만(DuckDNS 토큰은 SSM에만 있다), 상태 자체가 인프라의 상세 기록이라서
    # 버킷의 기본 암호화에만 기대지 않고 요청에서도 암호화를 명시한다.
    encrypt = true
  }
}
