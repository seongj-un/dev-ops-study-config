#!/bin/bash
# render.sh가 ubuntu:24.04 컨테이너 안에서 돌리는 검사다(/w = render.sh의 출력 디렉터리). 인스턴스와 같은 배포판의 도구로 본다.
#   1. cloud-init schema: user data가 cloud-init의 스키마에 맞는가
#   2. systemd-analyze verify: 유닛 파일의 문법과 참조(ExecStart 경로 등)가 맞는가
#   3. duckdns-update를 가짜 aws·curl로 돌려, 토큰이 명령줄 인자와 출력에 나오지 않고 curl의 표준 입력으로만 가는지 본다
set -euo pipefail
fail() { echo "실패: $*" >&2; exit 1; }

apt-get update -qq >/dev/null
apt-get install -y -qq cloud-init systemd >/dev/null 2>&1
echo "cloud-init $(cloud-init --version 2>&1 | awk '{print $NF}'), $(systemctl --version | head -n1)"

cloud-init schema --config-file /w/rendered.yaml --annotate

# write_files를 제자리에 풀어 유닛이 가리키는 실행 파일이 실제로 있게 한다.
cp -a /w/files/. /
systemd-analyze verify /etc/systemd/system/duckdns-update.service /etc/systemd/system/duckdns-update.timer \
  /etc/systemd/system/devops-bootstrap.service
echo "systemd-analyze verify: 경고 없음"

# 가짜 aws·curl: PATH에서 /usr/local/sbin이 /usr/bin보다 앞이다. 받은 인자와 표준 입력을 파일에 적는다.
token=0123abcd-0000-4000-8000-00000000beef
cat >/usr/local/sbin/aws <<EOF
#!/bin/bash
echo "\$*" >>/tmp/aws-argv
echo $token
EOF
cat >/usr/local/sbin/curl <<'EOF'
#!/bin/bash
echo "$*" >>/tmp/curl-argv
case "$*" in
  *api/token*) echo IMDSTOKEN ;;
  *public-ipv4*) echo 203.0.113.7 ;;
  *"-K -"*) cat >>/tmp/curl-stdin; echo "${DUCKDNS_REPLY:-OK}" ;;
  *) exit 22 ;;
esac
EOF
chmod +x /usr/local/sbin/aws /usr/local/sbin/curl

res=$(duckdns-update 2>&1) || fail "duckdns-update가 실패했다: $res"
echo "모의 실행 출력: $res"
[ "$res" = "DuckDNS: myshort.duckdns.org -> 203.0.113.7" ] || fail "출력이 예상과 다르다"
grep -q -- "--with-decryption --region ap-northeast-2 --name /dev-ops-study/duckdns-token" /tmp/aws-argv || fail "aws 인자가 다르다"
grep -q "X-aws-ec2-metadata-token: IMDSTOKEN" /tmp/curl-argv || fail "IMDSv2 토큰을 헤더로 보내지 않았다"
grep -q "$token" /tmp/curl-argv && fail "토큰이 curl의 명령줄 인자에 나타났다"
grep -qx "url = \"https://www.duckdns.org/update?domains=myshort&token=$token&ip=203.0.113.7\"" /tmp/curl-stdin ||
  fail "curl 표준 입력의 설정이 예상과 다르다"

if res=$(DUCKDNS_REPLY=KO duckdns-update 2>&1); then fail "KO 응답인데 성공으로 끝났다"; fi
case $res in *"$token"*) fail "KO일 때 토큰이 출력됐다" ;; esac
echo "KO 응답: 실패로 끝나고 토큰은 출력하지 않는다 ($res)"
