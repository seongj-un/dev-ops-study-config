# 입력 변수. 기본값이 없는 duckdns_subdomain과 admin_cidr는 필수라서 plan·apply에 -var로 넘겨야 한다(사람마다 값이 다르기 때문이다).
# 나머지는 이 저장소가 검증한 값을 기본값으로 둔다. 바꾸면 그 조합은 검증하지 않은 것이 된다.

variable "region" {
  description = "리소스를 만들 AWS 리전. 서브넷은 이 리전의 a 가용 영역에 만든다."
  type        = string
  default     = "ap-northeast-2"
}

variable "duckdns_subdomain" {
  description = "DuckDNS 서브도메인(.duckdns.org 없이). 예: myshort이면 prod는 myshort.duckdns.org, dev는 dev.myshort.duckdns.org이다."
  type        = string

  # DNS 레이블 규칙이다: 1~63자, 소문자·숫자·하이픈만, 하이픈으로 시작하거나 끝날 수 없다.
  # 이 값은 cloud-init의 셸 스크립트, systemd 유닛, URL에 그대로 들어간다. 따옴표·공백·세미콜론 같은 문자가 섞이면 스크립트가 깨지거나 명령이 덧붙을 수 있어서
  # (그리고 오타는 부팅이 끝난 뒤에야 알게 되어 비용만 나간다) plan 단계에서 막는다.
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.duckdns_subdomain))
    error_message = "duckdns_subdomain은 1~63자의 소문자, 숫자, 하이픈이어야 하고 하이픈으로 시작하거나 끝날 수 없다(예: myshort)."
  }
}

variable "admin_cidr" {
  description = "k3s API 서버(6443)에 접속할 수 있는 관리자 IP. IPv4 주소 하나를 가리키는 /32여야 한다. 예: $(curl -s https://checkip.amazonaws.com)/32"
  type        = string

  # 6443으로 받는 kubectl 요청은 kubeconfig의 클라이언트 인증서(cluster-admin)로 인증한다. 전 세계에 열면 인증이 뚫리기 전에도 스캔과 무차별 시도를 그대로 받으므로
  # 내 IP 하나로 좁힌다. /32가 아닌 값(특히 0.0.0.0/0)이 실수로 들어가 API 서버가 열리는 것을 막으려고 형식을 강제한다.
  # cidrnetmask는 올바른 IPv4 CIDR이 아니면 오류를 내므로 can()으로 형식을 확인하고, endswith로 /32임을 확인한다.
  validation {
    condition     = can(cidrnetmask(var.admin_cidr)) && endswith(var.admin_cidr, "/32")
    error_message = "admin_cidr는 IPv4 주소 하나를 가리키는 /32 CIDR이어야 한다. 예: 203.0.113.7/32 (내 공인 IP: curl -s https://checkip.amazonaws.com)"
  }
}

variable "instance_type" {
  description = "EC2 인스턴스 유형. m7i-flex.large는 2 vCPU, 8 GiB이고 AWS 무료 플랜 대상 유형이다."
  type        = string
  default     = "m7i-flex.large"
}

variable "k3s_version" {
  description = "설치할 k3s 버전(INSTALL_K3S_VERSION에 들어가는 형식). 로컬 k3d 클러스터와 같은 버전이다."
  type        = string
  default     = "v1.35.5+k3s1"

  # 이 값은 부팅 중에 k3s 설치 스크립트의 버전 지정(INSTALL_K3S_VERSION)으로 쓰인다. 형식이 틀리면 설치가 부팅 중에 실패하고, 그걸 알게 되는 것은 몇 분 뒤다.
  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.]+)?\\+k3s[0-9]+$", var.k3s_version))
    error_message = "k3s_version은 v1.35.5+k3s1 같은 형식이어야 한다."
  }
}

variable "helm_version" {
  description = "설치할 Helm 버전(정확한 버전). ArgoCD를 설치할 때만 쓰는 도구다."
  type        = string
  default     = "v4.3.0"

  # 이 값은 부팅 중에 Helm을 내려받을 버전으로 쓰인다. 위 k3s_version과 같은 이유로 형식을 미리 확인한다.
  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.]+)?$", var.helm_version))
    error_message = "helm_version은 v4.3.0 같은 형식이어야 한다."
  }
}

variable "argocd_chart_version" {
  description = "설치할 Helm 차트 argo/argo-cd의 버전. bootstrap/argocd/values.yaml이 가정하는 차트 버전과 같아야 한다."
  type        = string
  default     = "10.9.4"

  # 값 파일(bootstrap/argocd/values.yaml)은 맨 위 주석에 적힌 차트 버전을 기준으로 쓰였다. 이 값을 올릴 때는 값 파일의 버전 표기와 함께 바꾸고
  # 차트의 변경 이력을 확인한다. 형식은 차트 버전(SemVer, v 없이)이다.
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.]+)?$", var.argocd_chart_version))
    error_message = "argocd_chart_version은 10.9.4 같은 형식이어야 한다(v 접두사 없음)."
  }
}

variable "duckdns_token_parameter" {
  description = "DuckDNS 토큰을 담은 SSM Parameter Store SecureString의 이름. 인스턴스가 부팅할 때 이 값을 읽는다. 사람이 미리 만들어 둔다(README 참고)."
  type        = string
  default     = "/dev-ops-study/duckdns-token"

  # 이 이름은 iam.tf에서 IAM 정책의 리소스 ARN을 만드는 데 문자열로 이어 붙인다: arn:aws:ssm:<리전>:<계정>:parameter<이름>.
  # 계층형 이름(/로 시작)의 ARN은 parameter/dev-ops-study/... 가 되는데, /로 시작하지 않으면 parameter와 이름 사이에 /가 없는 ARN(parameterfoo)이 만들어져서
  # 어떤 파라미터와도 맞지 않는다. 그러면 권한이 조용히 빠져서 부팅 중에 AccessDenied로만 드러난다. 그래서 /로 시작하는 이름만 받는다.
  # 문자 집합은 Parameter Store 이름에 허용되는 문자(영문자, 숫자, . - _ /)다.
  validation {
    condition     = can(regex("^/[a-zA-Z0-9_./-]+$", var.duckdns_token_parameter))
    error_message = "duckdns_token_parameter는 /로 시작하고 영문자, 숫자, . - _ / 만 쓴 이름이어야 한다(예: /dev-ops-study/duckdns-token)."
  }
}

variable "config_repo_url" {
  description = "설정 저장소의 URL. cloud-init이 부팅 중에 ArgoCD의 루트 Application(argocd/root.yaml)을 여기서 가져온다. ArgoCD는 이 저장소를 읽어 앱을 배포한다."
  type        = string
  default     = "https://github.com/seongj-un/dev-ops-study-config"
}

variable "config_repo_ref" {
  description = "설정 저장소에서 가져올 Git ref(브랜치 또는 태그 이름)."
  type        = string
  default     = "main"
}
