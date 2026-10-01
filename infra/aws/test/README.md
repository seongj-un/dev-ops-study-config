# cloud-init 템플릿 검사

`infra/aws/cloud-init.yaml.tftpl`을 `ec2.tf`와 같은 방식(`templatefile`, 같은 변수 이름)으로 렌더링하고 검사한다.
AWS에 접속하지 않고 아무것도 만들지 않는다. 필요한 것: Terraform, python3(PyYAML), Docker(없으면 `NO_DOCKER=1`).

첫 줄은 결과를 임시 디렉터리에 남기고, 둘째 줄은 결과 디렉터리를 정한다(`rendered.yaml`, `user-data.b64`, `user-data.gz`, `files/<write_files 경로>`).
셋째 줄은 도커가 필요한 검사를 건너뛴다. 블록 안에 `#` 주석을 두지 않는 것은 zsh 때문이다(`interactivecomments`가 꺼져 있으면 `#`이 인자가 된다).

```bash
infra/aws/test/render.sh
infra/aws/test/render.sh /tmp/ci
NO_DOCKER=1 infra/aws/test/render.sh
```

검사하는 것:

| 검사 | 왜 |
| --- | --- |
| 시험용 값으로 렌더링, `config_repo_url` 끝의 `.git` 유무와 무관하게 결과가 같은지 | 템플릿 문법 오류와 raw 주소 계산을 plan 전에 잡는다 |
| 셸 문법이 끼어들 수 있는 값 7개가 렌더링에서 거부되는지 | `bootstrap.env`는 root가 `source` 한다. 템플릿의 `regex()`가 막아야 한다 |
| `ec2.tf`와 같은 `base64gzip(templatefile(...))`을 만들어 base64를 푼 gzip이 16384바이트 이하인지, 압축을 풀면 원문과 같은지 | EC2 user data 한도는 base64로 바꾸기 전 바이트(여기서는 gzip 압축본)로 16KB다. 압축 전 원문의 크기는 참고로만 출력한다 |
| 스크립트·유닛·키가 렌더링 전후로 같은지 | 스크립트에 Terraform 보간(`${`, `%{`)이 섞이면 Terraform이 글자를 바꾼다 |
| `argocd-values.yaml`의 값이 `bootstrap/argocd/values.yaml`과 같은지 | 템플릿은 주석 줄·빈 줄만 뺀다. 블록 스칼라 안의 `#` 줄처럼 값이 바뀌는 경우를 잡는다 |
| shellcheck(`koalaman/shellcheck:stable`) | 렌더링된 스크립트와 이 디렉터리의 스크립트 |
| `cloud-init schema`, `systemd-analyze verify`(ubuntu:24.04) | 인스턴스와 같은 배포판의 도구로 user data와 유닛 파일을 본다 |
| cloud-init의 `util.decomp_gzip`으로 압축본을 풀면 원문과 같은지(ubuntu:24.04) | cloud-init이 user data를 읽을 때 쓰는 함수로, gzip을 스스로 푸는지 확인한다 |
| `aws-cli.asc`의 지문, 스크립트의 키 풀기 방법(ubuntu:24.04의 gpg) | AWS CLI zip 서명 검사에 쓰는 키가 AWS 문서의 키(`FB5D…475C`)인지, armor 체크섬이 맞는지 |
| `duckdns-update` 모의 실행(가짜 aws·curl) | 토큰이 curl의 명령줄 인자와 출력에 나오지 않고 표준 입력으로만 가는지, KO 응답이면 실패하는지 |

`container-checks.sh`는 `render.sh`가 ubuntu:24.04 컨테이너 안에서 돌리는 부분이다(따로 돌리지 않는다).
컨테이너는 `docker run --rm`으로 띄워 검사가 끝나면 지워진다. 처음에는 cloud-init 패키지를 설치하느라 1~3분 걸린다.
