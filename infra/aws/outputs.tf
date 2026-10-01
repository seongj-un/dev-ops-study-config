output "instance_id" {
  description = "EC2 인스턴스 ID."
  value       = aws_instance.k3s.id
}

output "public_ip" {
  description = "인스턴스의 공인 IPv4. 자동으로 받은 주소라서 인스턴스를 멈췄다 시작하면 바뀐다(DuckDNS 업데이터가 이름을 새 IP로 갱신한다)."
  value       = aws_instance.k3s.public_ip
}

output "urls" {
  description = "접속 주소(지금은 평문 HTTP. TLS는 나중에 붙인다). DuckDNS는 <서브도메인>.duckdns.org 아래의 모든 이름을 같은 IP로 풀어 주므로 두 주소가 한 인스턴스로 간다. ArgoCD는 공개 주소가 없다(argocd_access 출력 참고)."
  value = {
    prod = "http://${var.duckdns_subdomain}.duckdns.org"
    dev  = "http://dev.${var.duckdns_subdomain}.duckdns.org"
  }
}

output "ssm_shell_command" {
  description = "SSH 없이 인스턴스에 셸을 여는 명령(SSM Session Manager). 로컬에 AWS CLI와 session-manager-plugin이 필요하다(플러그인이 없으면 README의 send-command 방법을 쓴다)."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.k3s.id}"
}

# kubeconfig를 SSM Run Command로 받아 오는 명령. terraform output -raw kubeconfig_fetch_hint 로 출력해서 그대로 붙여 넣는다.
#  - 붙여 넣을 명령에는 # 주석을 두지 않는다. zsh는 interactivecomments 옵션이 꺼져 있으면(기본값) 대화형 입력의 #을 주석으로 보지 않아서
#    "# 1) ..." 같은 줄이 명령이나 문법 오류가 된다. 설명은 이 주석과 README에 두고, 꼭 볼 주의 사항은 마지막 echo가 출력한다.
#  - 이 heredoc 안에서는 셸 변수를 ${}가 아니라 $KCFG처럼 중괄호 없이 적는다(${는 Terraform의 보간 문법이라서 Terraform이 먼저 해석하려 든다).
#  - 전제: devops-bootstrap이 k3s 설치(4단계)를 끝낸 뒤여야 한다. 그 전에는 /etc/rancher/k3s/k3s.yaml이 없어서 cat이 실패하고 받은 파일이 빈다.
#  - 저장 위치는 저장소 밖의 ~/.kube/dev-ops-study-aws.yaml이다. 이 파일은 클러스터 관리자(cluster-admin) 자격 증명이라 커밋하면 안 된다.
#    infra/aws/.gitignore도 kubeconfig*를 막지만 그 규칙은 infra/aws 폴더 안에서만 듣는다. 새로 만드는 파일은 umask 077로 처음부터 나만 읽게 한다.
#  - send-command의 출력(곧 이 kubeconfig 전체, 클라이언트 키 포함)은 SSM의 명령 기록에 약 30일 남는다. 그동안 이 계정에서
#    ssm:GetCommandInvocation 권한이 있는 사람은 다시 읽을 수 있다.
#  - 서버 주소를 127.0.0.1 대신 DuckDNS 이름으로 바꾼다. k3s 인증서의 tls-san에 이 이름이 들어 있어서 TLS 검증이 통과한다.
#  - 마지막 확인: 보안 그룹은 6443을 admin_cidr에만 연다. 지금 공인 IP가 admin_cidr와 다르면 kubectl이 응답 없이 멈춘다.
output "kubeconfig_fetch_hint" {
  description = "kubeconfig를 SSM Run Command로 받아 ~/.kube/dev-ops-study-aws.yaml에 저장하는 명령(SSH 없이). 서버 주소는 DuckDNS 이름으로 바꾼다."
  value       = <<-EOT
    mkdir -p "$HOME/.kube"
    KCFG=$HOME/.kube/dev-ops-study-aws.yaml
    CMD_ID=$(aws ssm send-command --region ${var.region} --instance-ids ${aws_instance.k3s.id} --document-name AWS-RunShellScript --parameters '{"commands":["cat /etc/rancher/k3s/k3s.yaml"]}' --query Command.CommandId --output text)
    aws ssm wait command-executed --region ${var.region} --instance-id ${aws_instance.k3s.id} --command-id "$CMD_ID"
    (umask 077 && aws ssm get-command-invocation --region ${var.region} --instance-id ${aws_instance.k3s.id} --command-id "$CMD_ID" --query StandardOutputContent --output text >"$KCFG")
    sed -i.bak 's#https://127.0.0.1:6443#https://${var.duckdns_subdomain}.duckdns.org:6443#' "$KCFG" && rm "$KCFG.bak"
    chmod 600 "$KCFG"
    KUBECONFIG=$KCFG kubectl get nodes
    echo '주의: 이 파일은 cluster-admin 자격 증명이다. 저장소에 넣지 않는다. 같은 내용이 SSM 명령 기록에 약 30일 남는다.'
  EOT
}

# ArgoCD UI는 인터넷에 공개하지 않는다. 지금은 평문 HTTP뿐이라서, 공개하면 로그인할 때 admin 비밀번호가 인터넷을 평문으로 지나간다.
# 그래서 HTTPS(cert-manager + Let's Encrypt)가 붙기 전에는 Ingress를 만들지 않고, kubectl port-forward로 내 PC의 localhost에 연결해서 쓴다.
# port-forward는 k3s API 서버(6443)를 거쳐 가는 연결이다. 6443은 TLS이고 보안 그룹이 admin_cidr에만 열어 두므로 비밀번호가 평문으로 나가지 않는다.
# ArgoCD의 공개 Ingress는 HTTPS가 붙은 뒤에 다시 만든다.
# 주석을 두지 않는 이유와 ${} 대신 $HOME처럼 적는 이유는 위 kubeconfig_fetch_hint와 같다. port-forward는 Ctrl-C로 끝낼 때까지
# 터미널을 붙잡으므로 맨 끝에 두고, 초기 비밀번호를 먼저 출력한다.
output "argocd_access" {
  description = "ArgoCD UI에 접속하는 방법. 공개 주소 없이 kubectl port-forward를 쓴다(kubeconfig_fetch_hint로 kubeconfig를 먼저 받는다)."
  value       = <<-EOT
    export KUBECONFIG=$HOME/.kube/dev-ops-study-aws.yaml
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
    echo '브라우저에서 http://localhost:8080 을 연다. 사용자는 admin, 비밀번호는 위 줄이다. 끝내려면 Ctrl-C.'
    kubectl -n argocd port-forward svc/argocd-server 8080:80
  EOT
}
