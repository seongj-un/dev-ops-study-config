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
  description = "SSH 없이 인스턴스에 셸을 여는 명령(SSM Session Manager). 로컬에 AWS CLI와 session-manager-plugin이 필요하다."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.k3s.id}"
}

# 여러 줄이라 terraform output -raw kubeconfig_fetch_hint 로 그대로 출력해서 복사한다.
# 이 heredoc 안에서는 셸 변수를 ${}가 아니라 $CMD_ID처럼 중괄호 없이 적는다(${는 Terraform의 보간 문법이라서 셸 변수로 쓰면 Terraform이 먼저 해석하려 든다).
output "kubeconfig_fetch_hint" {
  description = "kubeconfig를 SSM으로 받아 오는 방법. SSH 포트가 없으므로 SSM Run Command로 인스턴스의 /etc/rancher/k3s/k3s.yaml을 읽고, 서버 주소를 DuckDNS 이름으로 바꾼다."
  value       = <<-EOT
    # kubeconfig는 클러스터 관리자(cluster-admin) 자격 증명이다. 받은 파일은 나만 읽게 두고 저장소에 올리지 않는다.
    # 전제: cloud-init이 k3s 설치를 끝낸 뒤여야 한다(apply 직후 몇 분 동안은 파일이 없다).

    # 1) SSM Run Command로 인스턴스의 kubeconfig를 읽는다(SSH 없이).
    CMD_ID=$(aws ssm send-command --region ${var.region} --instance-ids ${aws_instance.k3s.id} \
      --document-name AWS-RunShellScript --parameters '{"commands":["cat /etc/rancher/k3s/k3s.yaml"]}' \
      --query Command.CommandId --output text)
    aws ssm wait command-executed --region ${var.region} --instance-id ${aws_instance.k3s.id} --command-id "$CMD_ID"
    aws ssm get-command-invocation --region ${var.region} --instance-id ${aws_instance.k3s.id} --command-id "$CMD_ID" \
      --query StandardOutputContent --output text > kubeconfig.yaml
    chmod 600 kubeconfig.yaml

    # 2) 서버 주소를 127.0.0.1 대신 DuckDNS 이름으로 바꾼다(k3s 인증서의 tls-san에 이 이름이 들어 있어서 TLS 검증이 통과한다).
    sed -i.bak 's#https://127.0.0.1:6443#https://${var.duckdns_subdomain}.duckdns.org:6443#' kubeconfig.yaml && rm kubeconfig.yaml.bak

    # 3) 확인. 보안 그룹은 6443을 admin_cidr에만 연다: 지금 공인 IP가 admin_cidr와 다르면 연결이 막힌다.
    KUBECONFIG=$PWD/kubeconfig.yaml kubectl get nodes
  EOT
}

# ArgoCD UI는 인터넷에 공개하지 않는다. 지금은 평문 HTTP뿐이라서, 공개하면 로그인할 때 admin 비밀번호가 인터넷을 평문으로 지나간다.
# 그래서 HTTPS(cert-manager + Let's Encrypt)가 붙기 전에는 Ingress를 만들지 않고, kubectl port-forward로 내 PC의 localhost에 연결해서 쓴다.
# port-forward는 k3s API 서버(6443)를 거쳐 가는 연결이다. 6443은 TLS이고 보안 그룹이 admin_cidr에만 열어 두므로 비밀번호가 평문으로 나가지 않는다.
# ArgoCD의 공개 Ingress는 HTTPS가 붙은 뒤에 다시 만든다.
# 이 heredoc에서도 셸 변수는 ${}가 아니라 $PWD처럼 중괄호 없이 적는다.
output "argocd_access" {
  description = "ArgoCD UI에 접속하는 방법. 공개 주소 없이 kubectl port-forward를 쓴다(kubeconfig_fetch_hint로 kubeconfig를 먼저 받는다)."
  value       = <<-EOT
    # 1) kubeconfig를 받는다: terraform output -raw kubeconfig_fetch_hint 의 명령을 실행해 kubeconfig.yaml을 만든다.
    export KUBECONFIG=$PWD/kubeconfig.yaml

    # 2) ArgoCD 서버를 내 PC의 8080 포트로 연결한다(이 명령은 계속 떠 있다. 다른 터미널에서 이어서 작업한다).
    kubectl -n argocd port-forward svc/argocd-server 8080:80

    # 3) 브라우저에서 http://localhost:8080 을 연다. 사용자는 admin, 초기 비밀번호는 아래 명령으로 읽는다.
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  EOT
}
