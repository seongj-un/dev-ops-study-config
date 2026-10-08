#!/usr/bin/env bash
# 명령 한 번으로 infra/aws의 EC2/k3s 환경 전체를 지운다(terraform destroy). infra/bootstrap(상태 버킷, 예산, OIDC 역할)은 건드리지 않는다.
# 사용법: infra/aws/down.sh [--yes]   (--help)
# 다시 실행해도 안전하다: 이미 비어 있으면 "지울 것이 없다"고 알리고 끝난다.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'USAGE'
사용법: infra/aws/down.sh [--yes]

  --yes   삭제 계획을 보여 준 뒤 묻지 않고 지운다.

하는 일: 사전 점검 -> terraform init -> plan -destroy 요약 -> 확인 -> 저장한 계획으로 destroy -> 남은 리소스 확인
환경 변수: DUCKDNS_SUBDOMAIN(기본 dev-ops-study), STATE_BUCKET
USAGE
}

for arg in "$@"; do
  case $arg in
    --yes | -y) ASSUME_YES=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "알 수 없는 인자: $arg" ;;
  esac
done

say "== 사전 점검 =="
preflight_tools
preflight_aws
# destroy에도 같은 변수가 필요하다(값은 검증만 통과하면 된다). 관리자 IP는 화면에 쓰지 않는다.
preflight_ip

say ""
say "== terraform =="
phase_start=$SECONDS
tf_init
# 저장한 destroy 계획을 그대로 적용한다. 화면에서 확인한 것과 지워지는 것이 같다는 점이 terraform destroy를 바로 실행하는 것과 다르다(결과는 같다).
tf plan -destroy -input=false -no-color -out="$WORK/destroy.tfplan" >"$WORK/plan.txt" 2>"$WORK/plan.err" || {
  cat "$WORK/plan.err" >&2
  die "terraform plan -destroy 실패"
}
phase_done "terraform init/plan -destroy" "$phase_start"

summarize_plan "$WORK/destroy.tfplan"
if [ "$PLAN_DELETE" -eq 0 ] && [ "$PLAN_REPLACE" -eq 0 ]; then
  say "지울 리소스가 없다. 이미 비어 있다."
else
  say "인스턴스 안의 모든 것(PostgreSQL 데이터, ArgoCD 설정)이 사라진다. 공부용이라 괜찮고, up.sh로 처음부터 다시 올라온다."
  confirm "위 리소스를 모두 삭제할까?" || die "취소했다. 아무것도 지우지 않았다."
  phase_start=$SECONDS
  tf apply -input=false -no-color "$WORK/destroy.tfplan" >"$WORK/destroy.txt" 2>&1 || {
    tail -n 30 "$WORK/destroy.txt" >&2
    die "destroy 실패. 같은 명령을 다시 실행하면 남은 것을 이어서 지운다."
  }
  phase_done "terraform destroy" "$phase_start"
fi

# 지운 클러스터를 가리키는 kubeconfig는 쓸모없는 cluster-admin 자격 증명이다. up.sh가 만든 그 파일만 지운다.
if [ -e "$KUBECONFIG_PATH" ]; then
  rm -f "$KUBECONFIG_PATH"
  say "kubeconfig 삭제: $KUBECONFIG_PATH"
fi

# 읽기 전용 확인: 남은 인스턴스(종료된 것은 한 시간쯤 목록에 남고 과금되지 않는다)와 볼륨(남으면 계속 과금).
say ""
say "== 남은 리소스 확인 =="
find_instance
if [ -z "$INSTANCE_ID" ]; then
  say "살아 있는 인스턴스: 없음"
else
  warn "인스턴스 $INSTANCE_ID 가 $INSTANCE_STATE 상태로 남아 있다(종료 진행 중일 수 있다. 잠시 뒤 다시 확인한다)."
fi
vols=$(awsr ec2 describe-volumes --filters Name=tag:Project,Values=dev-ops-study --query 'Volumes[].VolumeId' --output text) || vols="(조회 실패)"
if [ -z "$vols" ]; then
  say "남은 EBS 볼륨: 없음"
else
  warn "남은 EBS 볼륨: $vols (남으면 계속 과금된다. 인스턴스 종료가 끝나면 사라지는지 본다)"
fi

print_timing
say ""
say "남아 있는 것(의도한 것): 상태 버킷, 예산 알림, GitHub OIDC 역할(infra/bootstrap), SSM 파라미터(DuckDNS 토큰, Discord 웹훅 URL), DuckDNS 서브도메인."
say "Let's Encrypt 주의: 같은 이름 조합의 인증서는 주당 5번까지만 중복 발급된다. 지우고 다시 만들기를 반복하면 한도에 걸릴 수 있다."
say "  연습 중에는 staging 발급자를 쓰고, 운영 발급자 인증서는 꼭 필요할 때만 새로 받는다."
