# cloud-init 템플릿 검사

`infra/aws/cloud-init.yaml.tftpl`을 `ec2.tf`와 같은 방식(`templatefile`, 같은 변수 이름)으로 렌더링하고 검사한다.
AWS에 접속하지 않고 아무것도 만들지 않는다. 필요한 것: Terraform, python3(PyYAML), Docker(없으면 `NO_DOCKER=1`).

```bash
infra/aws/test/render.sh            # 결과는 임시 디렉터리에 남는다
infra/aws/test/render.sh /tmp/ci    # 결과 디렉터리를 정한다: rendered.yaml, files/<write_files 경로>
NO_DOCKER=1 infra/aws/test/render.sh
```

검사하는 것:

| 검사 | 왜 |
| --- | --- |
| 시험용 값으로 렌더링, `config_repo_url` 끝의 `.git` 유무와 무관하게 결과가 같은지 | 템플릿 문법 오류와 raw 주소 계산을 plan 전에 잡는다 |
| 셸 문법이 끼어들 수 있는 값 7개가 렌더링에서 거부되는지 | `bootstrap.env`는 root가 `source` 한다. 템플릿의 `regex()`가 막아야 한다 |
| 크기 16384바이트 이하 | EC2 user data는 base64로 바꾸기 전 원문이 16KB까지다 |
| 스크립트·유닛이 렌더링 전후로 같은지 | 스크립트에 Terraform 보간(`${`, `%{`)이 섞이면 Terraform이 글자를 바꾼다 |
| `argocd-values.yaml`의 값이 `bootstrap/argocd/values.yaml`과 같은지 | 템플릿은 주석 줄·빈 줄만 뺀다. 블록 스칼라 안의 `#` 줄처럼 값이 바뀌는 경우를 잡는다 |
| shellcheck(`koalaman/shellcheck:stable`) | 렌더링된 스크립트와 이 디렉터리의 스크립트 |
| `cloud-init schema`, `systemd-analyze verify`(ubuntu:24.04) | 인스턴스와 같은 배포판의 도구로 user data와 유닛 파일을 본다 |
| `duckdns-update` 모의 실행(가짜 aws·curl) | 토큰이 curl의 명령줄 인자와 출력에 나오지 않고 표준 입력으로만 가는지, KO 응답이면 실패하는지 |

`container-checks.sh`는 `render.sh`가 ubuntu:24.04 컨테이너 안에서 돌리는 부분이다(따로 돌리지 않는다).
컨테이너는 `docker run --rm`으로 띄워 검사가 끝나면 지워진다. 처음에는 cloud-init 패키지를 설치하느라 1~3분 걸린다.
