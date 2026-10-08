#!/usr/bin/env bash
# 명령 한 번으로 EC2/k3s 환경 전체를 만든다: terraform apply + 부팅 뒤 기다림(SSM, 부트스트랩, DNS, kubeconfig, ArgoCD).
# 사용법: infra/aws/up.sh [--yes] [--allow-replace]   (--help)
# 다시 실행해도 안전하다: 이미 있으면 계획이 "변경 없음"이고, 기다림 단계만 다시 확인한다.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 기다림 제한(초). 환경 변수로 바꿀 수 있다. 기본값은 README의 부팅 타임라인(전체 약 9~13분)에 여유를 둔 값이다.
T_RUNNING=${T_RUNNING:-600}
T_SSM=${T_SSM:-600}
T_BOOTSTRAP=${T_BOOTSTRAP:-1500}
T_DNS=${T_DNS:-600}
T_ARGO=${T_ARGO:-1200}

ALLOW_REPLACE=0
usage() {
  cat <<'USAGE'
사용법: infra/aws/up.sh [--yes] [--allow-replace]

  --yes            계획을 보여 준 뒤 묻지 않고 적용한다.
  --allow-replace  계획에 리소스 교체·삭제가 있어도 --yes로 진행한다(없으면 --yes여도 멈춘다. 인스턴스 교체는 안의 데이터가 사라진다).

하는 일: 사전 점검 -> terraform init/plan/apply -> 인스턴스 running -> SSM Online -> 부트스트랩 완료 표시
         -> DuckDNS가 새 IP를 가리킴 -> kubeconfig 저장(~/.kube/dev-ops-study-aws.yaml) -> ArgoCD Application 전부 Synced/Healthy
환경 변수: DUCKDNS_SUBDOMAIN(기본 dev-ops-study), STATE_BUCKET, T_RUNNING/T_SSM/T_BOOTSTRAP/T_DNS/T_ARGO(초 단위 제한)
USAGE
}

for arg in "$@"; do
  case $arg in
    --yes | -y) ASSUME_YES=1 ;;
    --allow-replace) ALLOW_REPLACE=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "알 수 없는 인자: $arg" ;;
  esac
done

# ---- 1. 사전 점검 -------------------------------------------------------------
say "== 사전 점검 =="
preflight_tools
preflight_aws
preflight_ip
preflight_ssm_params

# ---- 2. 멈춘 인스턴스 처리 ----------------------------------------------------
# 멈춘 인스턴스는 공인 IP가 없다. 그 상태로 plan하면 state(옛 IP)와 실제가 어긋난 채로 계획이 만들어지고, 시작하면 IP가 또 바뀐다.
# 그래서 있으면 먼저 켜서 state와 실제를 맞춘 뒤 plan한다. (켜는 것은 과금이 다시 시작된다는 뜻이다.)
find_instance
phase_start=$SECONDS
case ${INSTANCE_STATE:-} in
  stopped | stopping)
    say "인스턴스 $INSTANCE_ID 가 $INSTANCE_STATE 상태다. plan이 어긋나지 않도록 먼저 시작한다."
    if [ "$INSTANCE_STATE" = stopping ]; then
      awsr ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
    fi
    awsr ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
    phase_done "멈춘 인스턴스 시작 요청" "$phase_start"
    ;;
  "") say "기존 인스턴스가 없다. 새로 만든다." ;;
  *) say "인스턴스 $INSTANCE_ID 상태: $INSTANCE_STATE" ;;
esac

# ---- 3. terraform init / plan / apply -----------------------------------------
say ""
say "== terraform =="
phase_start=$SECONDS
tf_init
# 인스턴스를 켠 직후라면 공인 IP가 배정되길 기다린다(그 전에 refresh하면 IP가 비어 있어 불필요한 변경이 보인다).
if [ -n "${INSTANCE_ID:-}" ]; then
  awsr ec2 wait instance-running --instance-ids "$INSTANCE_ID"
fi
plan_rc=0
# -detailed-exitcode: 0 변경 없음, 1 오류, 2 변경 있음. 계획 본문은 파일로 버린다(속성 값 전체가 있다).
tf plan -input=false -no-color -detailed-exitcode -out="$WORK/aws.tfplan" >"$WORK/plan.txt" 2>"$WORK/plan.err" || plan_rc=$?
if [ "$plan_rc" = 1 ]; then
  show_masked "$WORK/plan.err"
  die "terraform plan 실패"
fi
phase_done "terraform init/plan" "$phase_start"

if [ "$plan_rc" = 0 ]; then
  say "변경 없음. apply는 건너뛰고 기다림 단계만 확인한다."
else
  summarize_plan "$WORK/aws.tfplan"
  if [ "${PLAN_INSTANCE_REPLACED:-0}" -gt 0 ]; then
    warn "EC2 인스턴스가 교체(삭제 후 생성)된다. 안의 데이터(DB 포함)가 모두 사라지고 클러스터가 처음부터 다시 올라온다."
  fi
  if [ "$ASSUME_YES" = 1 ] && { [ "${PLAN_REPLACE:-0}" -gt 0 ] || [ "${PLAN_DELETE:-0}" -gt 0 ]; } && [ "$ALLOW_REPLACE" != 1 ]; then
    die "계획에 교체 또는 삭제가 있다. --yes만으로는 진행하지 않는다. 계획을 확인했다면 --yes --allow-replace로 다시 실행한다."
  fi
  confirm "위 계획을 apply할까?" || die "취소했다. (이미 시작한 인스턴스는 그대로 켜져 있다. 필요하면 직접 멈춘다.)"
  phase_start=$SECONDS
  tf apply -input=false -no-color "$WORK/aws.tfplan" >"$WORK/apply.txt" 2>&1 || {
    # apply 출력은 리소스 ID와 오류뿐이고 비밀이 없다. 실패 원인을 보이기 위해 꼬리를 낸다.
    show_masked "$WORK/apply.txt" 30
    die "terraform apply 실패. 같은 명령을 다시 실행하면 이어서 진행한다."
  }
  phase_done "terraform apply" "$phase_start"
fi

INSTANCE_ID=$(tf output -raw instance_id) || die "instance_id 출력을 읽지 못했다"

# ---- 4. 부팅 뒤 기다림 --------------------------------------------------------
say ""
say "== 부팅 뒤 기다림 =="

check_running() {
  local s
  s=$(instance_attr "$INSTANCE_ID" State.Name 2>/dev/null) || s="조회 실패"
  WAIT_MSG="상태 $s"
  [ "$s" = running ]
}
phase_start=$SECONDS
wait_for "인스턴스 running" "$T_RUNNING" 5 check_running || die "인스턴스가 running이 되지 않았다"
phase_done "인스턴스 running" "$phase_start"

check_ssm() {
  local s
  s=$(awsr ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null) || s="조회 실패"
  [ "$s" = None ] && s="미등록"
  WAIT_MSG="SSM $s"
  [ "$s" = Online ]
}
phase_start=$SECONDS
wait_for "SSM Online" "$T_SSM" 10 check_ssm || die "SSM 에이전트가 Online이 되지 않았다. 인스턴스 프로파일(AmazonSSMManagedInstanceCore)과 네트워크를 확인한다."
phase_done "SSM Online" "$phase_start"

# 부트스트랩 완료 표시(/var/lib/devops-bootstrap.done)는 시작할 때마다 지워지고 성공해야 생긴다. 그런데 멈췄다 시작한 인스턴스는
# 서비스가 지우기 전까지 지난 부팅의 표시가 남아 있다. 표시가 이번 부팅보다 새것인지(표시 나이 < 가동 시간)를 함께 본다.
# 원격에서는 마지막 STEP 줄과 서비스 상태, 완료 표시의 신선도만 읽는다. 로그 본문은 읽지 않는다.
# 원격에서 풀려야 하는 $변수가 많아 작은따옴표로 감싼다(여기서 펼치면 안 된다).
# shellcheck disable=SC2016
BOOT_CHECK='f=/var/lib/devops-bootstrap.done
fresh=no
if [ -s "$f" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$f") )); up=$(cut -d. -f1 /proc/uptime)
  [ "$age" -lt "$up" ] && fresh=yes
fi
echo "fresh: $fresh"
echo "state: $(systemctl is-active devops-bootstrap 2>/dev/null)"
echo "step: $(grep "STEP:" /var/log/devops-bootstrap.log 2>/dev/null | tail -n 1 | sed "s/^[^ ]* //")"'
check_bootstrap() {
  local out state step fresh
  out=$(ssm_run "$INSTANCE_ID" "$BOOT_CHECK" 2>/dev/null) || { WAIT_MSG="SSM 명령 실패(재시도)"; return 1; }
  fresh=$(sed -n 's/^fresh: //p' <<<"$out")
  state=$(sed -n 's/^state: //p' <<<"$out")
  step=$(sed -n 's/^step: //p' <<<"$out")
  WAIT_MSG="${step:-시작 전} (서비스 ${state:-?})"
  if [ "$state" = failed ]; then
    die "부트스트랩 서비스가 failed다(마지막: ${step:-없음}). README의 \"실패한 부트스트랩 다시 돌리기\"로 원인을 보고 고친 뒤 up.sh를 다시 실행한다."
  fi
  [ "$fresh" = yes ] && [ "$state" != activating ]
}
phase_start=$SECONDS
wait_for "부트스트랩 완료" "$T_BOOTSTRAP" 20 check_bootstrap || die "부트스트랩이 제한 시간 안에 끝나지 않았다(마지막: ${WAIT_MSG}). README의 진행 확인으로 로그를 본다."
phase_done "부트스트랩 완료" "$phase_start"

resolve_ip() {
  local name=$1 ip="" server
  # 로컬 DNS 캐시에 남은 옛 답이나 음성 캐시를 피하려고 공개 리졸버에 직접 묻는다.
  # 네트워크에 따라 특정 리졸버로 가는 UDP 53이 막혀 있다(이 프로젝트의 맥에서는 1.1.1.1이 시간 초과, 8.8.8.8은 됨).
  # 그래서 1) HTTPS로 묻는 DoH(443은 거의 열려 있다) 2) 공개 리졸버 두 곳 순서로 시도하고, 처음 얻은 답을 쓴다.
  ip=$(curl -fsS --max-time 5 -H 'accept: application/dns-json' \
        "https://cloudflare-dns.com/dns-query?name=${name}&type=A" 2>/dev/null |
       jq -r '[.Answer[]? | select(.type == 1) | .data] | first // empty' 2>/dev/null) || ip=""
  for server in 8.8.8.8 1.1.1.1; do
    [ -n "$ip" ] && break
    if command -v dig >/dev/null 2>&1; then
      ip=$(dig +short +time=3 +tries=1 A "$name" "@$server" 2>/dev/null | grep -E '^[0-9.]+$' | head -n 1) || ip=""
    elif command -v host >/dev/null 2>&1; then
      ip=$(host -t A "$name" "$server" 2>/dev/null | awk '/has address/ {print $NF; exit}') || ip=""
    fi
  done
  printf '%s' "$ip"
}
DNS_NAME="$DUCKDNS_SUBDOMAIN.duckdns.org"
check_dns() {
  local want got
  want=$(instance_attr "$INSTANCE_ID" PublicIpAddress 2>/dev/null) || want=""
  got=$(resolve_ip "$DNS_NAME")
  if [ -z "$got" ]; then WAIT_MSG="$DNS_NAME 이 아직 풀리지 않는다"; else WAIT_MSG="$DNS_NAME 이 아직 다른 IP를 가리킨다"; fi
  # IP 값은 화면에 쓰지 않는다. 같은지만 본다.
  [ -n "$want" ] && [ "$want" != None ] && [ "$got" = "$want" ]
}
phase_start=$SECONDS
command -v dig >/dev/null 2>&1 || command -v host >/dev/null 2>&1 || die "DNS를 확인할 dig 또는 host 명령이 없다."
wait_for "DuckDNS가 새 IP를 가리킴" "$T_DNS" 15 check_dns || die "DuckDNS가 인스턴스 IP를 가리키지 않는다. SSM 토큰 파라미터(/dev-ops-study/duckdns-token)와 부트스트랩 로그의 'DuckDNS 갱신 실패'를 확인한다."
phase_done "DuckDNS 갱신" "$phase_start"

# kubeconfig는 cluster-admin 자격 증명이다. 화면에 찍지 않고, 저장소 밖에 umask 077로 처음부터 나만 읽게 만든다.
# 같은 디렉터리에 임시 파일로 쓴 뒤 옮겨서, 중간에 끊겨도 반쯤 쓴 파일이 남지 않는다. 내용은 SSM 명령 기록에 약 30일 남는다(README).
fetch_kubeconfig() {
  local raw tmp
  raw=$(ssm_run "$INSTANCE_ID" 'cat /etc/rancher/k3s/k3s.yaml') || return 1
  case $raw in apiVersion:*) ;; *) return 1 ;; esac
  mkdir -p "$(dirname "$KUBECONFIG_PATH")"
  tmp=$(umask 077 && mktemp "$KUBECONFIG_PATH.XXXXXX")
  # 서버 주소를 127.0.0.1 대신 DuckDNS 이름으로 바꾼다. k3s 인증서의 tls-san에 이 이름이 있어 TLS 검증이 통과한다.
  printf '%s\n' "$raw" | sed "s#https://127.0.0.1:6443#https://$DNS_NAME:6443#" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$KUBECONFIG_PATH"
}
phase_start=$SECONDS
fetch_kubeconfig || die "kubeconfig를 받지 못했다(k3s가 아직 설치 전이거나 SSM 명령 실패). up.sh를 다시 실행한다."
say "kubeconfig 저장: $KUBECONFIG_PATH (권한 600, 내용은 출력하지 않는다)"
phase_done "kubeconfig 저장" "$phase_start"

# ArgoCD Application 상태는 노드 안의 kubectl로 SSM을 통해 읽는다. 로컬 kubectl이나 6443 접근(admin_cidr)에 기대지 않고, 이름·동기화·건강만 가져온다.
EXPECTED_APPS=$(grep -l '^kind: Application$' "$REPO_ROOT/argocd/root.yaml" "$REPO_ROOT"/argocd/apps/*.yaml 2>/dev/null | wc -l | tr -d ' ')
ARGO_CMD='KUBECONFIG=/etc/rancher/k3s/k3s.yaml k3s kubectl -n argocd get applications.argoproj.io --no-headers -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>&1'
ARGO_LAST=""
check_argo() {
  local out total bad
  out=$(ssm_run "$INSTANCE_ID" "$ARGO_CMD" 2>/dev/null) || { WAIT_MSG="SSM 명령 실패(재시도)"; return 1; }
  if grep -qE '^(error:|Error from server|The connection to the server|Unable to connect|k3s: )' <<<"$out"; then
    WAIT_MSG="ArgoCD API 응답 없음"
    return 1
  fi
  ARGO_LAST=$out
  total=$(grep -c . <<<"$out" || true)
  bad=$(awk 'NF && !($2 == "Synced" && $3 == "Healthy")' <<<"$out" | wc -l | tr -d ' ')
  WAIT_MSG="Application $total개(예상 ${EXPECTED_APPS}개 이상) 중 준비 안 된 것 ${bad}개"
  [ "$total" -ge "${EXPECTED_APPS:-1}" ] && [ "$bad" = 0 ]
}
phase_start=$SECONDS
if ! wait_for "ArgoCD Application 전부 Synced/Healthy" "$T_ARGO" 20 check_argo; then
  say "Application 수: 확인된 $(grep -c . <<<"$ARGO_LAST" || true)개 / 예상 ${EXPECTED_APPS}개 이상 (모자라면 아직 만들어지지 않은 것이 있다)" >&2
  say "준비되지 않은 Application (이름 / 동기화 / 건강):" >&2
  awk 'NF && !($2 == "Synced" && $3 == "Healthy") {printf "  %s / %s / %s\n", $1, $2, $3}' <<<"$ARGO_LAST" >&2
  print_timing
  die "ArgoCD가 제한 시간 안에 모두 준비되지 않았다. 확인: KUBECONFIG=$KUBECONFIG_PATH kubectl -n argocd get applications"
fi
phase_done "ArgoCD 전부 Synced/Healthy" "$phase_start"

# ---- 5. 결과 ------------------------------------------------------------------
print_timing
say ""
say "준비 완료"
say "  prod: https://$DNS_NAME"
say "  dev : https://dev.$DNS_NAME"
say "  (인증서 발급 전이거나 Let's Encrypt staging 발급자면 브라우저가 경고할 수 있다)"
say "  kubectl: export KUBECONFIG=$KUBECONFIG_PATH"
say "  ArgoCD UI: terraform -chdir=infra/aws output -raw argocd_access  (port-forward 전용)"
say "  끝나면 infra/aws/down.sh 로 지운다. 켜 둔 시간만큼 과금된다."
