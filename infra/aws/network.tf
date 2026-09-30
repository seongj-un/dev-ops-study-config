# 네트워크: 전용 VPC 하나, 그 안에 공개(public) 서브넷 하나, 인터넷과는 인터넷 게이트웨이(IGW) 하나로만 이어진다.
# 계정의 기본 VPC를 쓰지 않고 새로 만드는 이유: 이 실습의 네트워크가 다른 것과 섞이지 않아서 destroy 한 번으로 흔적 없이 지워진다.
#
# NAT Gateway는 만들지 않는다(비용 가드레일). NAT Gateway는 켜 두는 시간마다 시간당 요금이, 지나가는 데이터 양마다 처리 요금이 붙는다.
# 대신 인스턴스를 공인 IPv4를 직접 받는 공개 서브넷에 두어서 IGW로 바로 인터넷에 나간다(패키지 설치, 이미지 pull, DuckDNS, SSM 모두 아웃바운드 HTTPS다).
# 그 대가로 인스턴스가 인터넷에 직접 닿으므로, 들어오는 길은 security.tf의 보안 그룹이 여는 포트로만 제한한다.

# VPC 흐름 로그(Flow Logs)는 켜지 않는다. 흐름 로그는 VPC 트래픽의 메타데이터(출발지, 목적지, 포트, 허용·거부 여부)를 CloudWatch Logs나 S3에 남기는 기능인데,
# 전달·저장 요금이 계속 붙는다. 이 VPC에는 공부용 인스턴스 한 대뿐이고 실습이 끝나면 통째로 지워져서, 그 기록을 조사할 일이 없는데 요금만 나간다.
# 운영 환경이라면 켜서 보안 그룹이 거부한 트래픽과 이상 징후를 남긴다.
# trivy:ignore:AVD-AWS-0178
resource "aws_vpc" "main" {
  # 10.20.0.0/16: 사설(RFC 1918) 대역이고 계정의 기본 VPC(172.31.0.0/16)와 겹치지 않는다. 나중에 VPC 피어링이나 VPN을 붙일 때
  # 주소 대역이 겹치면 이어 붙일 수 없어서 처음부터 다른 대역을 고른다. /16은 VPC에 쓸 수 있는 가장 큰 블록이고, 서브넷은 그 일부(/24)만 쓴다.
  cidr_block = "10.20.0.0/16"

  # enable_dns_support: VPC의 DNS 리졸버(VPC 대역의 +2 주소, 여기서는 10.20.0.2)로 이름을 풀 수 있게 한다.
  # 인스턴스가 github.com, duckdns.org, SSM 엔드포인트 같은 이름을 찾는 데 필요하다(기본값이 true이지만 의존하고 있다는 것을 드러내려고 적는다).
  enable_dns_support = true

  # enable_dns_hostnames: 공인 IP가 있는 인스턴스에 ec2-...amazonaws.com 형태의 공개 DNS 이름을 준다(기본값은 false).
  # 이 스택이 꼭 쓰는 기능은 아니다. 다만 나중에 인터페이스 VPC 엔드포인트의 프라이빗 DNS를 쓰려면 이 옵션과 위 옵션이 모두 켜져 있어야 해서 미리 켠다.
  enable_dns_hostnames = true

  tags = {
    Name = "${local.project}-vpc"
  }
}

# 인터넷 게이트웨이: VPC와 인터넷 사이의 출입구다. 공인 IP가 있는 인스턴스의 사설 IP와 공인 IP를 1:1로 바꿔 주고, 그 주소로 들어오고 나가는 트래픽을 지나 보낸다.
# IGW 자체에는 시간당 요금이 없다(NAT Gateway와 다르다). 요금이 붙는 것은 공인 IPv4 주소와 인터넷으로 나가는 데이터다.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.project}-igw"
  }
}

# 공개 서브넷: "공개"라는 성질은 서브넷 자체의 설정이 아니라 아래 라우트 테이블에서 나온다. 기본 경로(0.0.0.0/0)가 IGW로 가는 서브넷이 공개 서브넷이다.
# map_public_ip_on_launch = true는 의도한 설정이다(아래 주석).
# trivy:ignore:AVD-AWS-0164
resource "aws_subnet" "public" {
  vpc_id = aws_vpc.main.id

  # /24는 주소 256개다(AWS가 서브넷마다 5개를 예약해서 251개를 쓴다). 인스턴스 한 대에는 넘친다.
  cidr_block = "10.20.1.0/24"

  # 서브넷은 가용 영역 하나에 속하고 인스턴스도 그 영역에 만들어진다. 가용 영역 하나에 인스턴스 하나이므로 그 영역에 장애가 나면 중단된다(고가용성은 목표가 아니다).
  availability_zone = "${var.region}a"

  # 이 서브넷에 뜨는 인스턴스에 공인 IPv4를 자동으로 붙인다. 인스턴스가 인터넷에 나가려면 공인 IP가 있어야 한다:
  # NAT이 없으므로 인터넷으로 나가는 주소 변환은 IGW가 맡는데, IGW는 공인 IP가 있는 인스턴스의 트래픽만 내보낸다.
  # Elastic IP는 만들지 않는다. 고정 IP가 필요하지 않다: 자동으로 받은 IP는 인스턴스를 멈췄다 시작하면 바뀌지만 DuckDNS 업데이터가 5분마다 이름을 현재 IP로 갱신한다.
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.project}-public-${var.region}a"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  # 기본 경로: VPC 밖으로 가는 모든 IPv4 트래픽(0.0.0.0/0)을 IGW로 보낸다. VPC 안(10.20.0.0/16)으로 가는 경로는 AWS가 local 경로로 자동으로 넣는다.
  # 경로를 이 테이블 안에 인라인으로 적었다. 같은 테이블에 aws_route 리소스를 함께 쓰면 서로 덮어써서 충돌하므로 둘을 섞지 않는다.
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.project}-public"
  }
}

# 서브넷을 위 라우트 테이블에 연결한다. 연결하지 않은 서브넷은 VPC의 메인 라우트 테이블을 쓰는데, 그 테이블에는 local 경로뿐이라 인터넷으로 나갈 수 없다.
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
