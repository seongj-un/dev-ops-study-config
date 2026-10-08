#!/usr/bin/env bash
# up.sh와 down.sh가 함께 쓰는 함수 모음이다. 직접 실행하지 않고 source 한다.
# 출력 원칙: 공개 저장소의 CI가 아니라 내 터미널이지만 화면 공유·복사가 잦아서, 비밀과 관리자 IP, kubeconfig 내용은 어디에도 찍지 않는다.
#  - 관리자 IP는 TF_VAR_admin_cidr 환경 변수로만 terraform에 넘긴다(명령줄 인자에 두지 않는다). 화면에는 "현재 IP/32"라고만 쓴다.
#  - terraform plan의 본문(속성 값이 모두 나온다)은 임시 파일로 버리고, 개수·주소·동작만 요약한다.

# 호출하는 쪽(up.sh, down.sh)이 set -euo pipefail을 켠다. 이 파일은 그 설정을 이어받는다.
# 아래 변수(REPO_ROOT, PLAN_*, INSTANCE_*)는 source 한 쪽에서 쓰므로 이 파일만 검사하면 "안 쓴다"고 나온다.
# shellcheck disable=SC2034

REGION=${REGION:-ap-northeast-2}
STATE_BUCKET=${STATE_BUCKET:-dev-ops-study-tfstate-803879842357}
DUCKDNS_SUBDOMAIN=${DUCKDNS_SUBDOMAIN:-dev-ops-study}
KUBECONFIG_PATH=${KUBECONFIG_PATH:-$HOME/.kube/dev-ops-study-aws.yaml}
# 이 저장소가 검증한 Terraform 버전대(versions.tf의 ~> 1.16). CI는 1.16.4로 고정한다.
TF_VERSION_PREFIX=1.16.
SSM_PARAMS=(/dev-ops-study/duckdns-token /dev-ops-study/discord-webhook-url)

# 모든 aws 호출이 같은 리전을 쓰게 한다(리전을 빠뜨리면 다른 리전을 보고 "없다"고 오판한다). 페이저는 꺼서 스크립트가 멈추지 않게 한다.
export AWS_DEFAULT_REGION=$REGION AWS_PAGER=""
awsr() { aws --region "$REGION" "$@"; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# 임시 파일(계획, 계획 JSON)은 나만 읽는 디렉터리에 두고 끝날 때 지운다. 계획 파일에는 변수 값(관리자 IP)과 속성 전체가 들어 있다.
WORK=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/devops-infra.XXXXXX")
TIMING_PRINTED=0
# 어떤 경로로 끝나든(정상, die, set -e 중단, Ctrl-C) 임시 파일을 지우고, 단계별 시간이 아직 안 나왔다면 지금까지의 시간을 보인다.
on_exit() {
  local rc=$?
  if [ "$TIMING_PRINTED" = 0 ] && [ "${#PHASE_NAMES[@]}" -gt 0 ]; then
    print_timing >&2
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap on_exit EXIT

ASSUME_YES=0
PHASE_NAMES=()
PHASE_SECS=()
SCRIPT_START=$SECONDS

say() { printf '%s\n' "$*"; }
warn() { printf '경고: %s\n' "$*" >&2; }
die() { printf '오류: %s\n' "$*" >&2; exit 1; }
fmt_secs() { printf '%d분 %02d초' $(($1 / 60)) $(($1 % 60)); }

# mask: terraform이 남긴 출력(오류 포함)에서 관리자 IP를 가린다. AWS 오류가 보안 그룹 규칙의 CIDR을 그대로 되풀이할 수 있다.
# 터미널에 terraform 출력 파일의 내용을 낼 때는 항상 이 함수를 거친다(show_masked).
mask() {
  local ip=${TF_VAR_admin_cidr%/32}
  if [ -n "$ip" ]; then
    sed "s#${ip//./\\.}\(/32\)\{0,1\}#<현재 IP>#g"
  else
    cat
  fi
}
# show_masked <파일> [꼬리 줄 수]: 파일(의 마지막 N줄)을 IP를 가려 표준 오류로 낸다.
show_masked() {
  if [ -n "${2:-}" ]; then tail -n "$2" "$1" | mask >&2; else mask <"$1" >&2; fi
}

# phase_done <이름> <시작 SECONDS>: 단계별 걸린 시간을 기록하고 한 줄 출력한다.
phase_done() {
  local took=$((SECONDS - $2))
  PHASE_NAMES+=("$1")
  PHASE_SECS+=("$took")
  say "  -> $1 완료 ($(fmt_secs "$took"))"
}

print_timing() {
  local i
  TIMING_PRINTED=1
  say ""
  say "단계별 시간"
  for i in "${!PHASE_NAMES[@]}"; do
    printf '  %-28s %s\n' "${PHASE_NAMES[$i]}" "$(fmt_secs "${PHASE_SECS[$i]}")"
  done
  printf '  %-28s %s\n' "합계" "$(fmt_secs $((SECONDS - SCRIPT_START)))"
}

# confirm <질문>: --yes면 묻지 않고 통과한다. 터미널이 아니면(파이프, CI) --yes 없이는 진행하지 않는다.
confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -t 0 ] || die "확인을 받을 터미널이 없다. 계획을 확인했다면 --yes를 붙여 다시 실행한다."
  local answer
  read -r -p "$1 [y/N] " answer
  [ "$answer" = y ] || [ "$answer" = Y ] || [ "$answer" = yes ]
}

# ---- 사전 점검 ----------------------------------------------------------------

preflight_tools() {
  local t
  for t in aws terraform jq curl; do
    command -v "$t" >/dev/null 2>&1 || die "$t 명령이 없다. 설치한 뒤 다시 실행한다."
  done
  local tfv
  tfv=$(terraform version -json 2>/dev/null | jq -r '.terraform_version // empty') || tfv=""
  case $tfv in
    "$TF_VERSION_PREFIX"*) ;;
    *) die "Terraform ${TF_VERSION_PREFIX}x가 필요하다(지금: ${tfv:-알 수 없음}). versions.tf의 ~> 1.16과 CI의 1.16.4에 맞춘다. 버전이 다르면 user_data 압축 결과가 달라져 plan이 인스턴스 교체를 보여 줄 수 있다." ;;
  esac
}

preflight_aws() {
  # 자격 증명이 없거나 만료되면 여기서 멈추고 무엇을 하면 되는지 알려 준다. 계정 번호와 ARN은 찍지 않는다.
  if ! awsr sts get-caller-identity --query Account --output text >/dev/null 2>&1; then
    die "AWS 자격 증명이 없거나 만료됐다. 다음을 실행한 뒤 다시 한다: aws login --region $REGION"
  fi
  say "AWS 신원 확인 완료"
}

# 현재 공인 IP를 받아 TF_VAR_admin_cidr에 넣는다(k3s API 6443이 이 IP에만 열린다). 값은 화면에 찍지 않는다.
# preflight_ip [--fallback]: --fallback이면 조회에 실패해도 문서용 주소(203.0.113.1, RFC 5737)로 대신한다. destroy는 admin_cidr 값이
# 변수 검증만 통과하면 되기 때문이다(보안 그룹을 어차피 지운다).
preflight_ip() {
  local ip
  ip=$(curl -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]') || ip=""
  if [ -z "$ip" ] && [ "${1:-}" = --fallback ]; then
    say "현재 IP를 받지 못했다. 삭제에는 IP가 필요 없어서 문서용 주소(203.0.113.1/32)로 대신한다."
    ip=203.0.113.1
  fi
  [ -n "$ip" ] || die "현재 공인 IP를 받지 못했다(checkip.amazonaws.com). 네트워크를 확인한다. 빈 값으로 진행하면 /32만 든 admin_cidr이 되어 plan이 실패한다."
  # IPv4 모양과 각 자리 0~255를 확인한다. IPv6 응답이나 오류 페이지가 admin_cidr로 흘러 들어가지 못하게 한다.
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || die "받은 값이 IPv4가 아니다. IPv4로 나가는 네트워크에서 다시 한다."
  local o
  for o in "${BASH_REMATCH[@]:1}"; do
    [ "$((10#$o))" -le 255 ] || die "받은 값이 올바른 IPv4가 아니다."
  done
  export TF_VAR_admin_cidr="$ip/32"
  export TF_VAR_duckdns_subdomain=$DUCKDNS_SUBDOMAIN
  say "현재 IP/32 확인 완료 (값은 출력하지 않는다)"
}

# SSM 파라미터가 있는지 이름만 본다(값은 읽지 않는다). 없어도 부팅은 끝나지만 DuckDNS 갱신과 Discord 알림이 빠지므로 경고한다.
preflight_ssm_params() {
  local found p missing=0
  if ! found=$(awsr ssm describe-parameters \
    --parameter-filters "Key=Name,Values=$(IFS=,; echo "${SSM_PARAMS[*]}")" \
    --query 'Parameters[].Name' --output text 2>/dev/null); then
    warn "SSM 파라미터 존재를 확인하지 못했다(ssm:DescribeParameters 권한?). 없으면 부팅은 끝나도 DuckDNS 이름이 새 IP를 가리키지 않는다."
    return 0
  fi
  for p in "${SSM_PARAMS[@]}"; do
    case " $found " in
      *[[:space:]]"$p"[[:space:]]*) ;;
      *) warn "SSM 파라미터 $p 가 없다. README의 준비물 3~4번으로 만든다."; missing=1 ;;
    esac
  done
  [ "$missing" = 0 ] && say "SSM 파라미터 확인 완료 (이름만 확인)"
  return 0
}

# ---- Terraform ----------------------------------------------------------------

tf() { terraform -chdir="$SCRIPT_DIR" "$@"; }

tf_init() {
  say "terraform init (백엔드 버킷: $STATE_BUCKET)"
  if ! tf init -input=false -no-color -backend-config="bucket=$STATE_BUCKET" >"$WORK/init.txt" 2>&1; then
    show_masked "$WORK/init.txt"
    die "terraform init 실패"
  fi
}

# summarize_plan <계획 파일>: CI(terraform-plan.yml)와 같은 jq로 개수와 리소스 주소·동작·이유만 보인다. 속성 값과 출력 값은 싣지 않는다.
# 교체/삭제 개수는 PLAN_REPLACE, PLAN_DELETE, 인스턴스 영향은 PLAN_INSTANCE_REPLACED(0/1)에 남긴다.
summarize_plan() {
  local plan_json=$WORK/plan.json counts
  tf show -json "$1" >"$plan_json" || die "계획을 JSON으로 바꾸지 못했다"
  # jq를 먼저 변수에 받는다. 프로세스 치환으로 읽으면 jq가 실패해도 set -e가 보지 못한다(CI와 같은 이유).
  counts=$(jq -r '
    [.resource_changes[]? | .change.actions] as $a
    | [ ($a | map(select(. == ["create"])) | length),
        ($a | map(select(. == ["update"])) | length),
        ($a | map(select(contains(["create", "delete"]))) | length),
        ($a | map(select(. == ["delete"])) | length),
        ([.resource_drift[]?] | length) ]
    | @tsv' "$plan_json") || die "계획 요약(jq)에 실패했다"
  local create update replace delete drift
  read -r create update replace delete drift <<<"$counts"
  PLAN_REPLACE=$replace
  PLAN_DELETE=$delete
  PLAN_INSTANCE_REPLACED=$(jq -r '
    [.resource_changes[]? | select(.type == "aws_instance" and (.change.actions | contains(["delete"])))] | length' "$plan_json") \
    || die "계획 요약(jq)에 실패했다"
  say ""
  say "계획 요약: 추가 $create, 변경 $update, 교체 $replace, 삭제 $delete, Terraform 밖에서 바뀐 것 $drift"
  jq -r '
    def act:
      if . == ["create"] then "추가"
      elif . == ["update"] then "변경"
      elif . == ["delete"] then "삭제"
      elif . == ["delete", "create"] then "교체(지운 뒤 생성)"
      elif . == ["create", "delete"] then "교체(생성한 뒤 삭제)"
      else join("+") end;
    def why:
      {
        "replace_because_cannot_update": "제자리에서 바꿀 수 없는 속성이 바뀌었다",
        "replace_because_tainted": "tainted로 표시되어 있다",
        "replace_by_request": "-replace로 요청했다",
        "replace_by_triggers": "replace_triggered_by의 대상이 바뀌었다",
        "delete_because_no_resource_config": "코드에서 리소스가 없어졌다"
      } as $m
      | if . == null then "" else ($m[.] // .) end;
    [.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] as $c
    | if ($c | length) == 0 then "  바뀌는 리소스가 없다."
      else $c[] | "  \(.address)  \(.change.actions | act)  \(.action_reason | why)  \([.change.replace_paths[]? | map(tostring) | join(".")] | join(","))"
      end' "$plan_json" || die "계획 요약(jq)에 실패했다"
  say ""
}

# ---- EC2 / SSM ----------------------------------------------------------------

# 이 스택의 인스턴스(종료되지 않은 것)를 태그로 찾는다. 상태가 비어 있으면 인스턴스가 없다는 뜻이다. 읽기 전용이다.
# 결과: INSTANCE_ID, INSTANCE_STATE (없으면 둘 다 빈 값)
find_instance() {
  local out
  out=$(awsr ec2 describe-instances \
    --filters Name=tag:Project,Values=dev-ops-study \
    Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text) || die "EC2 인스턴스 조회 실패"
  INSTANCE_ID=""
  INSTANCE_STATE=""
  if [ -n "$out" ]; then
    [ "$(printf '%s\n' "$out" | wc -l)" -le 1 ] || die "Project=dev-ops-study 태그의 인스턴스가 둘 이상이다. 콘솔에서 확인한다."
    read -r INSTANCE_ID INSTANCE_STATE <<<"$out"
  fi
}

instance_attr() { # <인스턴스 ID> <JMESPath>
  awsr ec2 describe-instances --instance-ids "$1" --query "Reservations[0].Instances[0].$2" --output text
}

# wait_for <이름> <제한 초> <간격 초> <함수>: 함수가 0을 낼 때까지 기다린다. 함수는 WAIT_MSG에 지금 상태를 적는다.
# 상태가 바뀌거나 30초가 지나면 진행 줄을 찍는다. 제한이 지나면 1을 돌려주고, 호출한 쪽이 마지막 WAIT_MSG로 원인을 알린다.
wait_for() {
  local name=$1 limit=$2 interval=$3 fn=$4 start=$SECONDS last_msg="" last_print=$SECONDS
  WAIT_MSG=""
  say "[$name] 대기 시작 (최대 $((limit / 60))분)"
  until "$fn"; do
    if [ $((SECONDS - start)) -ge "$limit" ]; then
      say "[$name] 제한 시간 초과: ${WAIT_MSG:-상태 없음}" >&2
      return 1
    fi
    if [ "$WAIT_MSG" != "$last_msg" ] || [ $((SECONDS - last_print)) -ge 30 ]; then
      say "  ... $name: ${WAIT_MSG:-확인 중} ($((SECONDS - start))초)"
      last_msg=$WAIT_MSG
      last_print=$SECONDS
    fi
    sleep "$interval"
  done
}

# ssm_run <인스턴스 ID> <셸 스크립트>: SSM Run Command로 root 셸 스크립트를 돌리고 표준 출력을 낸다. SSH도 플러그인도 필요 없다.
# 출력은 SSM 명령 기록에 약 30일 남는다. 그래서 비밀이 나올 명령은 넣지 않는다(kubeconfig만 예외이고, 그 사실은 README에 적었다).
ssm_run() {
  local id=$1 script=$2 params cmd_id status i
  params=$(jq -cn --arg c "$script" '{commands: [$c]}') || return 1
  cmd_id=$(awsr ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters "$params" --query Command.CommandId --output text 2>/dev/null) || return 1
  for ((i = 0; i < 60; i++)); do
    sleep 2
    # 보낸 직후에는 InvocationDoesNotExist가 날 수 있다. 오류는 아직이라는 뜻으로 보고 다시 묻는다.
    status=$(awsr ssm get-command-invocation --instance-id "$id" --command-id "$cmd_id" --query Status --output text 2>/dev/null) || status=Pending
    case $status in
      Success)
        awsr ssm get-command-invocation --instance-id "$id" --command-id "$cmd_id" --query StandardOutputContent --output text
        return $?
        ;;
      Pending | InProgress | Delayed) ;;
      *) return 1 ;;
    esac
  done
  return 1
}
