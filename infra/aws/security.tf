# 보안 그룹: 인스턴스의 네트워크 인터페이스에 붙는 방화벽이다. 상태를 기억한다(stateful): 허용한 인바운드 연결의 응답은 따로 허용하지 않아도 나간다.
# 열어 둔 것은 80, 443(누구에게나)과 6443(관리자 IP 하나)뿐이다. 22(SSH)는 열지 않는다: 셸은 SSM Session Manager로 열고(iam.tf), 그 통신은 인스턴스가 밖으로 먼저 거는 연결이라 인바운드 포트가 필요 없다.
#
# 이 파일의 description 문자열은 영문 ASCII로 적는다. AWS가 보안 그룹과 규칙의 설명에 허용하는 문자는 영문자, 숫자, 공백, ._-:/()#,@[]+=&;{}!$* 뿐이라서
# 한글을 넣으면 API가 거부한다. 한글 설명은 이런 주석으로 적는다.
#
# 규칙은 그룹 안의 ingress/egress 블록(인라인)이 아니라 aws_vpc_security_group_*_rule 리소스로 하나씩 만든다.
#  - 규칙마다 AWS가 고유 ID를 주는데, 인라인 블록과 옛 aws_security_group_rule은 그 ID가 생기기 전에 만든 방식이라 description·tags를 다루는 데 한계가 있고
#    CIDR이 여럿이면 다루기 어렵다. 프로바이더 문서도 새 구성에는 이 리소스를 쓰라고 안내한다(규칙 하나에 CIDR 하나).
#  - 한 그룹에 인라인 블록과 규칙 리소스를 섞어 쓰면 서로 덮어쓴다. 그래서 그룹은 껍데기만 만들고 규칙은 모두 규칙 리소스로 둔다.
resource "aws_security_group" "k3s" {
  name        = "${local.project}-k3s"
  description = "k3s single node: HTTP/HTTPS from anywhere, Kubernetes API from the admin IP only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.project}-k3s"
  }
}

# 80: k3s에 기본으로 들어 있는 Ingress 컨트롤러(Traefik)가 받는다. 앱(prod, dev)이 이 포트로 열린다. ArgoCD UI는 열지 않는다:
# HTTPS가 붙기 전에는 admin 비밀번호가 평문 HTTP로 인터넷을 지나가므로, ArgoCD는 kubectl port-forward로만 접속한다(outputs.tf의 argocd_access).
# 출발지를 전 세계(0.0.0.0/0)로 연 이유: 이 서비스는 누구나 브라우저로 접속하는 웹 서비스다. 나중에 cert-manager로 Let's Encrypt 인증서를 받을 때(HTTP-01 방식)도
# 검증 요청이 고정되지 않은 여러 곳의 IP에서 오므로 특정 IP로 좁힐 수 없다.
resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.k3s.id
  description       = "HTTP from anywhere (Traefik ingress)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

# 443: 같은 Traefik의 HTTPS. 지금은 평문 HTTP로 시작하고 인증서(cert-manager + Let's Encrypt)는 나중에 붙이므로 이 포트로 서비스하는 앱은 아직 없다.
# 나중에 인증서를 붙일 때 보안 그룹까지 고치지 않도록 미리 열어 둔다.
resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.k3s.id
  description       = "HTTPS from anywhere (Traefik ingress)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# 6443: k3s API 서버(kubectl이 접속한다). 출발지를 관리자 IP 하나(/32)로 좁힌다.
# kubeconfig에는 cluster-admin 권한의 클라이언트 인증서가 들어 있어서, API 서버가 전 세계에 열려 있으면 인증 앞단까지 스캔과 무차별 시도가 그대로 닿는다.
# 공인 IP가 바뀌면(장소를 옮기거나 통신사가 새 IP를 주면) kubectl이 막힌다. 그때는 새 IP로 admin_cidr를 바꿔 apply한다(보안 그룹 규칙만 바뀌고 인스턴스는 다시 만들어지지 않는다).
resource "aws_vpc_security_group_ingress_rule" "kube_api" {
  security_group_id = aws_security_group.k3s.id
  description       = "Kubernetes API (k3s) from the admin IP only"
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
}

# 아웃바운드는 전부 허용한다. Terraform은 새 보안 그룹에서 AWS가 기본으로 넣는 "모두 허용" 아웃바운드 규칙을 지우므로, 필요하면 이렇게 직접 만들어야 한다.
# 전부 여는 이유: 인스턴스가 나가는 곳이 apt 미러, GitHub, 이미지 레지스트리(ghcr.io 등), Helm 차트 저장소, DuckDNS, SSM 엔드포인트처럼 많고 IP가 바뀌는 곳들이라
# IP나 포트로 좁히기 어렵다. 들어오는 쪽(위)을 좁게 두는 것이 이 구성의 방어선이다.
# ip_protocol = "-1"은 모든 프로토콜이다. 이때는 모든 포트가 열려서 포트를 적는 것이 의미가 없으므로 from_port와 to_port를 적지 않는다.
# 전부 여는 것은 의도한 설정이다(위 설명).
# trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.k3s.id
  description       = "All outbound (package mirrors, GitHub, registries, DuckDNS, SSM)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
