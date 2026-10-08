# infra/bootstrap

Terraform이 쓸 **원격 state 저장소(S3 버킷)** 와 **비용 알림(AWS Budgets)**, 그리고 **GitHub Actions가 AWS에 들어오는 길(OIDC 공급자와 plan 전용 역할)** 을 만드는 스택이다. 처음에 **한 번만** 실행한다.

- 다른 스택(`infra/aws`)은 이 스택이 만든 버킷에 자기 state를 저장한다.
- PR의 `terraform plan`(`.github/workflows/terraform-plan.yml`)은 이 스택이 만든 읽기 전용 역할을 OIDC로 맡는다. 저장소에 AWS 키를 두지 않는다([GitHub Actions용 OIDC](#github-actions용-oidc)).
- 공부하는 동안 돈이 새는 것을 이 스택의 예산 알림이 이메일로 알려 준다. 그래서 EC2처럼 비용이 드는 리소스를 만들기 **전에** 이 스택부터 적용한다("예산 먼저").

## 왜 원격 state 버킷이 필요한가

Terraform은 자기가 만든 리소스의 목록과 속성을 state 파일에 적어 둔다. 이 파일이 한 컴퓨터에만 있으면 그 컴퓨터가 고장 나거나 파일이 지워질 때 Terraform이 자기 리소스를 잊는다.
잊힌 리소스는 AWS에 그대로 남아 계속 과금된다. state를 S3에 두면 다음이 해결된다.

- 어느 컴퓨터에서 실행해도 같은 state를 본다.
- 버전 관리 덕에 state를 잘못 덮어써도 이전 버전으로 되돌릴 수 있다.
- 잠금으로 동시 실행을 막는다. DynamoDB 테이블은 쓰지 않는다. S3의 조건부 쓰기로 잠금 파일(`.tflock`)을 만드는 방식이다(backend의 `use_lockfile = true`, Terraform 1.10 이상).

## 만드는 것 (리소스 13개)

| 리소스 | 설정 | 이유 |
|---|---|---|
| S3 버킷 `dev-ops-study-tfstate-<계정 ID>` | `force_destroy = false` | 버킷 이름은 모든 계정이 공유하는 이름 공간에서 유일해야 해서 계정 ID를 붙인다. `force_destroy`는 지울 때의 안전장치다(아래 "정리") |
| 버전 관리 | 켬 | state를 덮어써도 이전 버전이 남는다 |
| 암호화 | SSE-S3 (`AES256`) | 추가 요금 없이 저장 시 암호화한다 |
| 퍼블릭 액세스 차단 | 네 가지 모두 켬 | 이 버킷이 공개될 이유가 없다 |
| 객체 소유권 | `BucketOwnerEnforced` | ACL을 끄고 IAM과 버킷 정책으로만 접근을 정한다 |
| 버킷 정책 | TLS가 아니면 거절 | HTTP로는 state가 오가지 못한다 |
| 수명 주기 | 이전 버전을 30일 뒤 삭제 | 이전 버전이 끝없이 쌓이지 않게 한다 |
| 예산 `dev-ops-study-monthly` | 월 $20 | 아래 "예산" |
| 예산 `dev-ops-study-early-warning` | 월 $5 | 조기 경보 |
| OIDC 공급자 `token.actions.githubusercontent.com` | audience `sts.amazonaws.com`, 지문 없음 | GitHub Actions의 토큰을 AWS가 믿게 한다(아래 "GitHub Actions용 OIDC") |
| IAM 역할 `dev-ops-study-github-plan` | 신뢰: 이 저장소의 PR과 `main`만, 최대 1시간 | CI의 `terraform plan`이 맡는 역할 |
| 역할에 `ReadOnlyAccess` 연결 | AWS 관리형 정책 | `plan`에 필요한 읽기 |
| 인라인 정책 `deny-secrets-and-writes` | 명시적 Deny 넷 | 이 프로젝트의 SSM 파라미터·Run Command 출력 읽기와 S3 쓰기를 막는다 |

각 설정이 왜 그런지는 `state_bucket.tf`, `budgets.tf`, `github_oidc.tf`의 주석에 적혀 있다. 변수(`variables.tf`)는 다음과 같고 `terraform apply -var budget_limit_usd=30`처럼 덮어쓸 수 있다.

| 변수 | 기본값 | 뜻 |
|---|---|---|
| `region` | `ap-northeast-2` | 버킷을 만들 리전. 만든 뒤에는 바꾸지 않는다 |
| `alert_email` | `seongjun154@naver.com` | 예산 알림을 받을 주소. 이미 이 저장소의 git 이력에 공개된 주소다 |
| `budget_limit_usd` | `20` | 월 예산 한도 |
| `early_warning_limit_usd` | `5` | 조기 경보 한도(월 예산보다 작아야 한다) |
| `github_oidc_sub_prefix` | `repo:seongj-un@173442979/dev-ops-study-config@1397588081` | 역할을 맡을 수 있는 토큰의 `sub` 앞부분(저장소). 저장소 이름을 바꾸면 고친다 |

## 왜 이 스택만 로컬 state인가

이 스택의 state는 S3가 아니라 이 디렉터리의 `terraform.tfstate` 파일(로컬)에 저장된다. `backend` 블록이 없기 때문이다. 이유는 닭과 달걀 문제다.

- `backend "s3"`를 쓰는 스택은 `terraform init` 때 그 버킷에 접속한다.
- 이 스택의 버킷은 이 스택의 `terraform apply`가 만든다. `init`은 `apply`보다 먼저 한다.
- 그러니 이 스택의 state까지 그 버킷에 두면 "버킷이 있어야 `init`이 되고, `init`이 돼야 버킷을 만든다"는 순환이 된다.

버킷을 만든 뒤에 state를 그 버킷으로 옮기는 방법(`terraform init -migrate-state`)도 있다. 하지만 그러면 정리(destroy) 때 버킷을 지우기 전에 state를 다시 로컬로 꺼내야 하는 순환이 생긴다.
이 스택은 한 번 만들고 거의 바꾸지 않으므로 로컬 state가 더 단순하다.

- 로컬 state 파일은 `.gitignore`가 제외한다(`*.tfstate*`, 그리고 provider를 받아 두는 `.terraform/`). state에는 리소스의 모든 속성이 평문으로 들어 있어서 저장소에 올리지 않는다.
- **이 파일을 잃으면** Terraform이 이 스택의 리소스를 잊는다(AWS의 버킷과 예산은 그대로 남는다). 이때 `terraform apply`는 이미 존재한다는 오류로 실패하므로 리소스마다 `terraform import`로 state에 되돌려 넣어야 한다.
  리소스가 13개라 감당할 만하지만 번거로우니, `apply`가 끝나면 `terraform.tfstate`를 다른 곳에 한 벌 복사해 두는 것이 좋다.

## 실행 순서

```bash
cd infra/bootstrap

aws login                     # 브라우저로 AWS에 로그인해 임시 자격 증명을 받는다
aws sts get-caller-identity   # 지금 어느 계정인지 확인한다. 이 계정 ID가 버킷 이름에 들어간다

terraform init                # provider를 내려받는다(.terraform.lock.hcl이 고정한 버전)
terraform apply               # 만들 리소스(처음이면 13개)를 보여 주고 yes를 기다린다
```

- `aws login`을 프로필 이름을 붙여서 했다면(`--profile NAME`) 먼저 `export AWS_PROFILE=NAME`을 한다.
- Terraform이 자격 증명을 찾지 못하면 `eval "$(aws configure export-credentials --format env)"`로 현재 셸의 환경 변수로 내보낸다(그 셸에서만 유효하다).
- 적용하는 자격 증명에는 S3 버킷 설정, Budgets 생성, IAM(OIDC 공급자·역할·정책) 권한이 필요하다(관리자 권한이면 충분하다).
- 계정에 같은 URL(`https://token.actions.githubusercontent.com`)의 OIDC 공급자가 이미 있으면 `apply`가 `EntityAlreadyExists`로 실패한다. 계정마다 하나만 만들 수 있어서다. 그때는 `terraform import aws_iam_openid_connect_provider.github <공급자 ARN>`으로 가져온다(`aws iam list-open-id-connect-providers`로 ARN을 본다).

끝나면 출력을 확인한다. `123456789012`는 예시 계정 ID다.

```bash
terraform output
# backend_config_arg   = "-backend-config=bucket=dev-ops-study-tfstate-123456789012"
# github_plan_role_arn = "arn:aws:iam::123456789012:role/dev-ops-study-github-plan"
# region               = "ap-northeast-2"
# state_bucket         = "dev-ops-study-tfstate-123456789012"
```

## infra/aws와 연결

`infra/aws`는 버킷 이름을 코드에 적지 않고 `init`할 때 넘긴다. backend 블록에는 변수·local·data 같은 참조를 쓸 수 없어서("Variables may not be used here") 계정 ID가 들어가는 버킷 이름을 미리 적어 둘 수 없기 때문이다.
이 스택의 `backend_config_arg` 출력이 그 인자다.

```bash
cd ../aws
terraform init "$(terraform -chdir=../bootstrap output -raw backend_config_arg)"
```

값에 따옴표를 넣지 않은 이유는 `outputs.tf`의 주석에 있다. `infra/aws`의 backend region은 이 스택의 `region`과 같아야 한다.

## GitHub Actions용 OIDC

`github_oidc.tf`는 GitHub Actions가 AWS 액세스 키 없이 AWS에 들어오는 길을 만든다. 잡마다 GitHub가 서명한 짧은 토큰을 STS가 확인하고, 역할의 신뢰 정책이 허락하는 저장소·이벤트에만 임시 자격 증명을 내준다.

- **OIDC 공급자**: 발급자 URL `https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com`. `thumbprint_list`는 적지 않는다. aws provider 6.x에서 선택 인자이고, AWS는 GitHub의 인증서를 자기의 신뢰 루트 CA 목록으로 검증해서 지문을 쓰지 않는다.
- **역할 `dev-ops-study-github-plan`**: `aud`가 `sts.amazonaws.com`이고 `sub`가 `<github_oidc_sub_prefix>:pull_request` 또는 `<github_oidc_sub_prefix>:ref:refs/heads/main`인 토큰만 받는다(`StringEquals`). 최대 세션 1시간.
- **권한**: `ReadOnlyAccess` + 명시적 Deny(이 프로젝트의 SSM 파라미터 값, `GetParametersByPath` 전부, Run Command 출력, S3 객체 쓰기·삭제).

왜 이렇게 했는지(왜 `*`가 아닌가, 왜 `main`도 믿는가, 무엇을 읽을 수 있고 무엇을 막았나), 저장소 변수·시크릿을 넣는 법은 [`infra/aws/README.md`의 "GitHub Actions에서 plan (OIDC)"](../aws/README.md#github-actions에서-plan-oidc)에 있다.
이 스택에 둔 이유: 역할을 `infra/aws`에 두면 그 스택을 `destroy`할 때 역할도 사라지고, 역할을 바꾸는 PR의 `plan`을 그 역할 자신이 돌리게 된다. 상태 버킷처럼 다른 스택보다 먼저 있고 오래 남는 것이라 여기에 둔다.

## 비용

- S3: state 파일은 수십 KB 안팎이고 이전 버전도 30일 뒤에 지워서, 저장 요금과 요청 요금이 한 달에 1센트에도 못 미친다.
- Budgets: 계정당 예산 2개까지는 무료라고 안내되어 있고, 이 스택이 만드는 예산이 정확히 2개다. 요금 규정은 바뀔 수 있으니 예산을 늘리기 전에 Billing 콘솔에서 확인한다.
- IAM(OIDC 공급자, 역할, 정책)과 STS의 역할 맡기는 요금이 없다.
- 이 스택에는 그 밖에 돈이 드는 리소스가 없다. 그래서 사실상 0원이다.

## 예산: 할 수 있는 것과 없는 것

| 예산 | 한도(기본) | 알림 |
|---|---|---|
| `dev-ops-study-monthly` | 월 $20 | 실제 사용액이 50% 초과, 실제 사용액이 100% 초과, 이번 달 말 예측 금액이 100% 초과 |
| `dev-ops-study-early-warning` | 월 $5 | 실제 사용액이 100% 초과(곧 $5 초과) |

알림은 `alert_email`로 온다.

- **알림만 한다.** 예산은 지출을 멈추지 않는다(Budget Actions로 자동 조치를 붙일 수는 있지만 붙이지 않았다). 계정이 Free 플랜이면 크레딧을 넘는 사용은 막히지만, 그렇지 않으면 이 알림이 유일한 경고다.
  그래서 "실습이 끝나면 `terraform destroy`"가 알림보다 확실한 방어다.
- **늦다.** 예산은 청구 데이터로 계산하고 그 데이터는 하루에 최대 3번 갱신된다(AWS 안내). 돈이 나간 뒤 몇 시간 늦게 알림이 올 수 있다.
- **크레딧을 뺀 금액으로 센다**(`include_credit = false`). 크레딧을 포함하면 크레딧이 깎아 준 만큼이 비용에서 빠진다. 그러면 크레딧이 남아 있는 동안에는 얼마를 쓰든 예산에 잡히는 금액이 0 근처에 머물러 알림이 울리지 않는다.
- **예측 알림은 새 계정에서 울리지 않을 수 있다.** 예측은 지금까지의 사용 이력으로 만드는데, 새 계정은 이력이 부족하기 때문이다.

## 정리(destroy)

이 스택은 프로젝트를 **완전히 정리할 때 맨 마지막에** 지운다.

1. **이 버킷을 쓰는 스택을 먼저 모두 `terraform destroy`한다**(`infra/aws` 등). 그 스택들의 state가 이 버킷에 있어서, 버킷을 먼저 지우면 그 스택이 만든 리소스가 state 없이 AWS에 남아 계속 과금된다.
2. **버킷을 비운다.** `force_destroy = false`라서 객체가 하나라도 남아 있으면 destroy가 버킷 삭제를 거부한다. 이것이 안전장치다. 버전 관리가 켜져 있으므로 "비운다"는 현재 객체뿐 아니라 **모든 이전 버전과 삭제 마커(delete marker)까지** 지운다는 뜻이다.
   `aws s3 rm --recursive`는 삭제 마커만 더할 뿐 이전 버전을 지우지 않아서 충분하지 않다. 다음 둘 중 하나를 쓴다.
   - 콘솔: S3 → 버킷 → "비우기(Empty)".
   - Terraform: `state_bucket.tf`의 `force_destroy`를 `true`로 바꾸고 `terraform apply`를 한 번 한다(이 값이 state에 기록되어야 destroy가 적용한다). 그 뒤 3번으로 간다.
3. `terraform destroy`. 예산 2개도 함께 사라진다(비용 알림이 끝난다). OIDC 공급자와 plan 역할도 사라져서 PR의 `terraform-plan` 워크플로는 역할을 맡지 못해 실패한다(필수 검사가 아니라 PR을 막지는 않는다).
4. 로컬의 `terraform.tfstate`는 지워도 된다.

버킷을 비우면 모든 스택의 state와 그 이전 버전이 영구 삭제되어 되돌릴 수 없다. 1번이 끝났는지 확인한 뒤에 한다.

## 검증 (AWS 자격 증명 없이)

```bash
cd infra/bootstrap
terraform fmt -check -recursive
terraform init -backend=false   # 이 스택에는 backend 블록이 없어서 -backend=false가 있으나 없으나 같다
terraform validate

# 저장소 루트에서
docker run --rm -v "$PWD":/w aquasec/trivy:0.70.0 config /w/infra/bootstrap
```

trivy는 두 가지를 지적한다. S3 서버 액세스 로깅이 꺼져 있다(AWS-0089)와 암호화가 고객 관리형 KMS 키가 아니다(AWS-0132)이다.
둘 다 이 프로젝트에서 일부러 택한 것이라 이유를 `state_bucket.tf`의 주석에 적고 `#trivy:ignore`로 예외 처리했다.

## 파일

| 파일 | 내용 |
|---|---|
| `versions.tf` | Terraform·provider 버전 범위, 로컬 state를 쓰는 이유 |
| `providers.tf` | AWS provider, 태그를 붙일 수 있는 모든 리소스에 붙는 태그(`Project`, `ManagedBy`) |
| `variables.tf` | 변수 5개 |
| `state_bucket.tf` | state 버킷과 그 설정 |
| `budgets.tf` | 예산 2개 |
| `github_oidc.tf` | GitHub Actions OIDC 공급자, plan 역할(신뢰 정책, `ReadOnlyAccess`, Deny 인라인 정책) |
| `outputs.tf` | `state_bucket`, `region`, `backend_config_arg`, `github_plan_role_arn` |
| `.terraform.lock.hcl` | provider 버전과 해시(맥 darwin_arm64, 리눅스 linux_amd64). 커밋한다 |
| `.gitignore` | `.terraform/`, `*.tfstate*` 등 |
