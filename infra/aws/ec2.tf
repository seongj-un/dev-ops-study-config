# EC2 인스턴스 한 대: k3s 단일 노드 클러스터가 여기서 돈다. 설치와 설정은 모두 cloud-init(user_data)이 첫 부팅 때 한다.

# Canonical(Ubuntu를 만드는 회사)이 SSM 공개 파라미터로 공개하는 Ubuntu 24.04 LTS(amd64, gp3 루트 볼륨) AMI의 ID. 'current'는 호출한 시점의 최신 이미지를 가리킨다.
# 이 파라미터를 읽으면 리전마다 다른 AMI ID를 코드에 적어 두지 않아도 된다.
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "k3s" {
  # AMI의 ID는 공개된 값이라서 insecure_value를 쓴다. value는 항상 sensitive로 표시되어서 그것을 쓰면 plan에서 ami가 (sensitive value)로 가려진다.
  ami           = data.aws_ssm_parameter.ubuntu_ami.insecure_value
  instance_type = var.instance_type

  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.k3s.id]
  iam_instance_profile   = aws_iam_instance_profile.k3s.name

  # 공인 IP를 받는다. 서브넷의 map_public_ip_on_launch와 같은 뜻이지만 여기에도 적는다: NAT이 없는 이 구성에서는 공인 IP가 있어야만 인스턴스가 인터넷에 나갈 수 있으므로
  # 인스턴스 정의만 읽어도 그 전제가 보이게 한다.
  associate_public_ip_address = true

  # key_name(키 페어)은 지정하지 않는다. SSH 포트(22)도 열지 않으므로 키가 있어도 쓸 곳이 없다. 셸은 SSM Session Manager로 연다(iam.tf).
  # credit_specification도 두지 않는다: CPU 크레딧 옵션은 T 계열(버스트 가능) 인스턴스에만 있는 설정이다.

  # IMDS(인스턴스 메타데이터 서비스, 169.254.169.254): 인스턴스가 자기 정보와 역할의 임시 자격 증명을 읽는 곳이다. DuckDNS 업데이터가 여기서 공인 IP를 읽는다.
  metadata_options {
    http_endpoint = "enabled"

    # IMDSv2 강제: 읽기 전에 PUT 요청으로 세션 토큰을 받아 헤더에 붙여야 한다. 단순 GET만 되는 IMDSv1은 서버 측 요청 위조(SSRF) 취약점 하나로
    # 역할의 자격 증명이 새어 나갈 수 있어서 막는다(토큰을 받는 PUT과 커스텀 헤더는 흔한 SSRF로는 만들기 어렵다).
    http_tokens = "required"

    # 토큰을 돌려주는 PUT 응답이 건널 수 있는 네트워크 홉 수를 1로 제한한다. 호스트 자신은 그 안에서 토큰을 받지만, k3s의 파드는 호스트 위의 가상 네트워크에 있어서
    # 응답이 호스트(라우터 역할)를 한 번 더 건너야 하므로 닿지 못한다. 토큰이 없으면 IMDSv2가 강제인 이 인스턴스에서는 메타데이터를 읽을 수 없다.
    # 그래서 파드가 침해되어도 이 인스턴스 역할(SSM 읽기 권한)을 가져갈 수 없다. 호스트 프로세스(systemd의 DuckDNS 업데이터, cloud-init)는 영향이 없다.
    # 예외: hostNetwork: true로 뜬 파드는 호스트의 네트워크를 그대로 써서 한 홉 더 건너지 않으므로 IMDS에 닿는다. 그런 파드를 띄우지 않는 것이 전제다.
    # 파드가 AWS 권한이 필요해지면 노드의 역할을 같이 쓰게 하지 말고 그 파드에 별도의 자격 증명을 준다.
    http_put_response_hop_limit = 1
  }

  root_block_device {
    # gp3: gp2보다 GiB당 단가가 낮고, 기본 성능(3,000 IOPS, 125 MiB/s)이 용량과 상관없이 따라온다.
    volume_type = "gp3"

    # 30 GiB: Ubuntu AMI의 기본 루트 볼륨은 8 GiB인데, 컨테이너 이미지(ArgoCD, PostgreSQL, Redis, 앱)와 로그가 쌓이는 k3s 노드에는 빠듯해서 키운다.
    volume_size = 30

    # 디스크 암호화. kms_key_id를 지정하지 않으면 계정의 기본 EBS 암호화 키(바꾸지 않았다면 AWS 관리형 aws/ebs)를 쓰고, 이 키는 별도 요금이 없다(고객 관리형 KMS 키는 월 요금이 붙는다).
    # 디스크에는 k3s 상태(Secret 포함)와 부팅 중에 만든 DB 비밀번호가 있어서, 저장된 데이터를 디스크 수준에서 암호화해 둔다.
    # 볼륨이나 스냅샷이 의도와 다르게 다른 곳에 붙거나 공유되더라도 KMS 키를 쓸 권한이 없으면 읽을 수 없다.
    encrypted = true

    # 인스턴스를 없앨 때 볼륨도 함께 지운다(루트 볼륨의 기본값이지만 명시한다). 볼륨만 남으면 인스턴스가 없어도 계속 과금된다.
    delete_on_termination = true
  }

  # EBS 볼륨은 인스턴스와 별개의 리소스로 과금되고 태그도 따로 붙는다. 같은 태그를 명시해서 비용 태그(Project)로 볼륨 비용도 걸러 보게 한다.
  volume_tags = merge(local.tags, {
    Name = "${local.project}-k3s-root"
  })

  # cloud-init이 첫 부팅 때 이 내용을 실행한다(k3s, Helm, ArgoCD 설치와 DuckDNS 갱신 설정).
  # 변수 이름은 cloud-init.yaml.tftpl과 맞춘 약속이라 함부로 바꾸면 안 된다.
  # argocd_values는 로컬 클러스터용 값 파일(bootstrap/argocd/values.yaml)을 그대로 넣는다(템플릿이 그 위에 덮어쓰는 부분은 cloud-init.yaml.tftpl을 본다).
  # 그래서 이 값 파일이 바뀌면 렌더링 결과가 달라지고, 아래 user_data_replace_on_change 때문에 다음 apply에서 인스턴스가 교체된다.
  #
  # user_data가 아니라 user_data_base64로, gzip으로 압축해서 넘긴다. 이유는 크기 한도다:
  #  - EC2는 user_data를 base64로 인코딩하기 전 원본 기준 16384바이트(16 KiB)까지만 받고, 프로바이더도 plan에서 이를 검사한다("expected length of user_data to be in the range (0 - 16384)").
  #    바이트 수라서 한글(UTF-8에서 글자당 3바이트)이 많으면 빨리 닿는다. 이 템플릿은 값 파일이 통째로 들어가고 한글 주석이 많아서, 작성 시점에 렌더링 결과가 약 15.8 KB로 한도에 바짝 닿아 있었다.
  #  - base64gzip은 문자열을 gzip으로 압축한 다음 base64로 인코딩한다. 압축하면 같은 내용이 약 6.6 KB가 된다. 압축본은 문자열(UTF-8)이 아닌 바이너리라서 user_data가 아니라 user_data_base64 인자로 넘긴다.
  #  - cloud-init은 gzip으로 압축된 user-data를 자동으로 알아보고 풀어서 원래의 cloud-config로 처리한다. 한도는 압축한 뒤의 크기에 적용된다.
  # 주의: 압축 결과의 바이트는 Terraform을 빌드한 Go 버전에 따라 달라질 수 있다. Terraform을 올린 뒤 살아 있는 인스턴스에 plan하면, 내용이 같아도 user_data_base64가 바뀐 것으로 보여
  # 교체가 제안될 수 있다. 이 실습은 쓸 때 만들고 끝나면 destroy하므로 감수한다: 원인이 압축 결과뿐인 교체 제안은 apply하지 말고, 그 세션이 끝난 뒤 destroy한다.
  user_data_base64 = base64gzip(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    aws_region           = var.region
    duckdns_subdomain    = var.duckdns_subdomain
    ssm_parameter_name   = var.duckdns_token_parameter
    k3s_version          = var.k3s_version
    helm_version         = var.helm_version
    argocd_chart_version = var.argocd_chart_version
    argocd_values        = file("${path.module}/../../bootstrap/argocd/values.yaml")
    config_repo_url      = var.config_repo_url
    config_repo_ref      = var.config_repo_ref
  }))

  # user_data(여기서는 user_data_base64)가 바뀌면 인스턴스를 교체(삭제 후 재생성)한다. cloud-init은 user_data를 인스턴스의 첫 부팅 때 한 번만 실행하므로(인스턴스가 바뀔 때만 다시 실행한다),
  # 기본 동작(인스턴스를 그대로 두고 user_data 속성만 바꾸는 것)으로는 바뀐 스크립트가 실행되지 않은 채 "반영된 것처럼" 보이게 된다.
  # 교체하면 인스턴스가 항상 "현재 코드가 만든 그대로" 부팅한다. 일회용 인스턴스(쓸 때 만들고 끝나면 destroy)라서 교체로 잃는 것이 없다.
  user_data_replace_on_change = true

  # 인스턴스의 cloud-init은 부팅 직후부터 인터넷(패키지, k3s, 이미지)과 SSM이 필요하다. 그런데 Terraform은 서브넷·보안 그룹·인스턴스 프로파일만 의존으로 보고,
  # 아래 리소스와의 순서는 보장하지 않는다(이들을 이 리소스가 참조하지 않기 때문이다). 순서가 어긋나면 인스턴스가 먼저 떠서 첫 네트워크 호출이 실패할 수 있어서 명시한다:
  #  - 라우트 테이블 연결: 기본 경로(0.0.0.0/0 → IGW)가 이 서브넷에 적용된 뒤여야 인터넷에 나간다.
  #  - 아웃바운드 규칙: Terraform이 기본 "모두 허용" 아웃바운드를 지웠으므로 이 규칙이 생기기 전에는 나가는 트래픽이 모두 막힌다.
  #  - 역할의 정책 둘: 인스턴스가 뜬 직후 SSM에서 토큰을 읽고 SSM 에이전트가 등록하려면 권한이 먼저 붙어 있어야 한다.
  depends_on = [
    aws_route_table_association.public,
    aws_vpc_security_group_egress_rule.all,
    aws_iam_role_policy_attachment.ssm_core,
    aws_iam_role_policy.duckdns_token,
  ]

  tags = {
    Name = "${local.project}-k3s"
  }

  lifecycle {
    # ami를 바꾸면 인스턴스가 교체된다. 그런데 위 data.aws_ssm_parameter의 'current'는 Canonical이 새 이미지를 낼 때마다 다른 ID를 돌려주므로, 코드를 하나도 고치지 않아도
    # 어느 날 plan이 "인스턴스 교체"를 보여 주고, 그 apply는 k3s 안의 상태(DB 포함)를 모두 지운다. 그 교체를 막으려고 처음 만들 때의 AMI를 유지한다.
    # 새 AMI가 필요할 때는 terraform apply -replace=aws_instance.k3s로 일부러 교체한다. 이 실습은 쓸 때 만들고 끝나면 destroy하므로 다음 apply는 어차피 그때의 최신 AMI로 만든다.
    ignore_changes = [ami]
  }
}
