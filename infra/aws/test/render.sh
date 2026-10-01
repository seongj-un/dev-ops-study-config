#!/usr/bin/env bash
# cloud-init.yaml.tftpl을 ec2.tf와 같은 방식(templatefile, 같은 변수 이름)으로 렌더링하고 검사한다. AWS에 접속하지 않고 아무것도 만들지 않는다.
#   사용: infra/aws/test/render.sh [출력 디렉터리]   (기본은 임시 디렉터리)
#   결과: <출력>/rendered.yaml(user data 원문), <출력>/user-data.b64(ec2.tf가 넘기는 base64gzip 그대로),
#         <출력>/user-data.gz(그 base64를 푼 gzip 바이트), <출력>/files/<경로>(write_files를 풀어 놓은 것)
#   NO_DOCKER=1이면 도커가 필요한 검사(shellcheck, cloud-init schema·gzip 풀기, systemd-analyze verify, AWS CLI 키 지문,
#   DuckDNS 모의 실행)를 건너뛴다. 크기·압축 왕복·내용 검사는 도커 없이도 한다.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
aws_dir=$(dirname "$here")
repo=$(cd "$aws_dir/../.." && pwd)
out=${1:-$(mktemp -d)}
mkdir -p "$out"
out=$(cd "$out" && pwd)
tf=$(mktemp -d)
trap 'rm -rf "$tf"' EXIT
fail() { echo "실패: $*" >&2; exit 1; }

# 시험용 값. 이름은 ec2.tf의 templatefile 호출과 같고, argocd_values는 저장소의 실제 파일이다.
export EXPECT_SUB=myshort
export EXPECT_ROOT_APP_URL=https://raw.githubusercontent.com/seongj-un/dev-ops-study-config/main/argocd/root.yaml
cat >"$tf/main.tf" <<EOF
locals {
  tpl = "$aws_dir/cloud-init.yaml.tftpl"
  vars = {
    aws_region           = "ap-northeast-2"
    duckdns_subdomain    = "$EXPECT_SUB"
    ssm_parameter_name   = "/dev-ops-study/duckdns-token"
    k3s_version          = "v1.35.8+k3s1"
    helm_version         = "v4.3.0"
    argocd_chart_version = "10.9.4"
    argocd_values        = file("$repo/bootstrap/argocd/values.yaml")
    config_repo_url      = "https://github.com/seongj-un/dev-ops-study-config"
    config_repo_ref      = "main"
  }
}
output "rendered" {
  value = templatefile(local.tpl, local.vars)
}
# ec2.tf의 user_data_base64와 같은 식이다. Terraform이 EC2에 실제로 보내는 값이 이것이다.
output "user_data_base64" {
  value = base64gzip(templatefile(local.tpl, local.vars))
}
# 저장소 주소 끝에 .git이 붙어도 raw 주소는 같아야 한다.
output "rendered_git_suffix" {
  value = templatefile(local.tpl, merge(local.vars, { config_repo_url = "https://github.com/seongj-un/dev-ops-study-config.git" }))
}
EOF

echo "== Terraform으로 렌더링 ($(terraform version | head -n1))"
terraform -chdir="$tf" init -input=false -no-color >/dev/null
terraform -chdir="$tf" apply -auto-approve -input=false -no-color >/dev/null
terraform -chdir="$tf" output -raw rendered >"$out/rendered.yaml"
terraform -chdir="$tf" output -raw user_data_base64 >"$out/user-data.b64"
terraform -chdir="$tf" output -raw rendered_git_suffix >"$tf/git-suffix.yaml"
cmp -s "$out/rendered.yaml" "$tf/git-suffix.yaml" || fail "config_repo_url 끝의 .git이 결과를 바꿨다"

# 셸 문법이 끼어들 수 있는 값은 plan에서 막혀야 한다(템플릿의 regex()).
# 먼저 정상 값이 console에서 통과하는지 본다: console이 늘 실패하는 환경이면 아래 거부 검사는 아무것도 증명하지 못한다.
echo "length(templatefile(local.tpl, local.vars))" | terraform -chdir="$tf" console >/dev/null ||
  fail "정상 값으로도 terraform console 렌더링이 실패했다"
for bad in 'duckdns_subdomain = "my.short"' 'duckdns_subdomain = "x;reboot"' 'aws_region = "ap-northeast-2 x"' \
  'k3s_version = "latest"' 'helm_version = "v4.3"' 'config_repo_url = "https://gitlab.com/a/b"' 'config_repo_ref = "main;id"'; do
  if echo "templatefile(local.tpl, merge(local.vars, { $bad }))" | terraform -chdir="$tf" console >/dev/null 2>&1; then
    fail "잘못된 값이 렌더링을 통과했다: $bad"
  fi
done
echo "잘못된 값 7개가 모두 렌더링에서 거부됐다"

# EC2 user data 한도는 base64로 바꾸기 전 바이트로 16384다. ec2.tf는 base64gzip을 넘기므로 그 바이트는 gzip 압축본이다:
# Terraform이 만든 base64를 풀어 크기를 재고, 압축을 풀면 원문과 바이트까지 같은지 본다(cloud-init은 풀어서 원문을 읽는다).
# 압축 전 원문의 크기는 한도와 상관없어서 참고로만 보여 준다.
base64 --decode <"$out/user-data.b64" >"$out/user-data.gz"
gz=$(wc -c <"$out/user-data.gz" | tr -d ' ')
[ "$gz" -le 16384 ] || fail "압축한 user data가 16384바이트를 넘는다: $gz"
gzip -dc <"$out/user-data.gz" | cmp -s - "$out/rendered.yaml" || fail "base64gzip을 풀어도 렌더링 원문과 같지 않다"
echo "크기: 압축본 $gz / 16384 바이트(EC2 한도), base64 $(wc -c <"$out/user-data.b64" | tr -d ' ') 바이트, 압축을 풀면 원문과 같다"
echo "참고: 압축 전 원문 $(wc -c <"$out/rendered.yaml" | tr -d ' ') 바이트(한도와 무관)"

echo "== YAML·내용 검사"
if python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$out/rendered.yaml" "$aws_dir/cloud-init.yaml.tftpl" "$repo/bootstrap/argocd/values.yaml" "$out" <<'PY'
import os, sys, yaml

rendered_path, tpl_path, values_path, out = sys.argv[1:5]
text = open(rendered_path, encoding="utf-8").read()
assert text.startswith("#cloud-config\n"), "첫 줄이 #cloud-config가 아니다"
r = yaml.safe_load(text)
# 템플릿 원본도 YAML로 읽힌다: Terraform 보간은 블록 스칼라 안의 글자일 뿐이다.
t = yaml.safe_load(open(tpl_path, encoding="utf-8"))
assert sorted(r) == ["runcmd", "write_files"], sorted(r)
rf = {f["path"]: f for f in r["write_files"]}
tf = {f["path"]: f for f in t["write_files"]}
assert rf.keys() == tf.keys()
templated = {"/etc/devops/bootstrap.env", "/etc/devops/argocd-values.yaml"}
for p in rf:
    if p not in templated:
        assert rf[p]["content"] == tf[p]["content"], p + ": Terraform이 내용을 바꿨다(스크립트·유닛·키에 Terraform 보간이 들어갔다)"
print("스크립트·유닛·키", len(rf) - len(templated), "개는 렌더링 전후가 같다")

orig = yaml.safe_load(open(values_path, encoding="utf-8"))
emb = yaml.safe_load(rf["/etc/devops/argocd-values.yaml"]["content"])
assert orig == emb, "argocd-values.yaml의 값이 bootstrap/argocd/values.yaml과 다르다"
print("argocd-values.yaml: 주석을 뺀", len(rf["/etc/devops/argocd-values.yaml"]["content"]), "바이트, 값은 원본과 같다")

env = dict(line.split("=", 1) for line in rf["/etc/devops/bootstrap.env"]["content"].splitlines())
assert env["DUCKDNS_SUBDOMAIN"] == os.environ["EXPECT_SUB"], env
assert env["ROOT_APP_URL"] == os.environ["EXPECT_ROOT_APP_URL"], env["ROOT_APP_URL"]
print("bootstrap.env:", env)

for p, f in rf.items():
    dst = os.path.join(out, "files", p.lstrip("/"))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(f["content"])
    os.chmod(dst, int(f.get("permissions", "0644"), 8))
PY
else
  ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$out/rendered.yaml"
  echo "경고: python3 PyYAML이 없어 YAML 문법만 봤다(ruby). 내용 검사와 도커 검사는 건너뛴다"
  exit 0
fi

if [ "${NO_DOCKER:-0}" = 1 ]; then
  echo "NO_DOCKER=1: 도커 검사를 건너뛴다"
  exit 0
fi

echo "== shellcheck (koalaman/shellcheck:stable)"
# bootstrap.env를 제자리에 두고 -x로 따라 읽게 해서, 거기서 오는 변수를 '정의되지 않음'으로 보지 않게 한다.
# -f gcc: 경고를 "파일:줄:열: 내용 [SC번호]" 한 줄로 낸다. 기본 형식은 원본 줄을 함께 찍는데, 이 이미지에는 UTF-8 로캘이 없어서
# 한글이 든 줄을 찍다가 출력이 깨진다(commitBuffer: invalid argument).
docker run --rm -v "$out/files:/w:ro" -v "$here:/t:ro" \
  -v "$out/files/etc/devops/bootstrap.env:/etc/devops/bootstrap.env:ro" \
  koalaman/shellcheck:stable -x -f gcc \
  /w/usr/local/bin/duckdns-update /w/usr/local/sbin/devops-bootstrap /t/render.sh /t/container-checks.sh
echo "shellcheck: 경고 없음"

echo "== cloud-init schema, systemd-analyze verify, DuckDNS 모의 실행 (ubuntu:24.04)"
docker run --rm -v "$out:/w:ro" -v "$here:/t:ro" ubuntu:24.04 bash /t/container-checks.sh
echo "== 모두 통과: $out"
