# dev-ops-study-config

데브옵스 공부용 URL 단축 서비스([seongj-un/dev-ops-study](https://github.com/seongj-un/dev-ops-study))의 **배포 설정 저장소**다.
Helm 차트, 환경별 값, 모니터링 플랫폼의 값, ArgoCD 정의가 여기에 있고, 클러스터에는 ArgoCD가 이 저장소를 읽어서 반영한다(GitOps).
앱과 플랫폼은 사람이나 CI가 클러스터에 `helm install`·`kubectl apply`로 직접 밀어 넣지 않는다. 클러스터에 무엇이 떠 있어야 하는지는 이 저장소의 `main`이 말해 준다
(손으로 하는 것은 ArgoCD 설치, 루트 Application 적용, Git에 둘 수 없는 Secret(DB 비밀번호, Grafana 관리자, Discord 웹훅) 생성뿐이다. 아래 부트스트랩. EC2에서는 이것도 부트스트랩 스크립트가 한다).

## 왜 앱 저장소와 분리했나

- **Git 로그가 곧 배포 이력이다.** 이 저장소의 커밋 하나는 "어느 환경에 어느 이미지를 올렸다(또는 설정을 바꿨다)"는 변경 하나다.
  "지금 무엇이 떠 있나, 언제 바뀌었나, 어디로 되돌리나"를 이 저장소의 로그와 `git revert`로 답할 수 있다.
- **권한과 보호 규칙을 따로 둔다.** 앱 저장소의 `main`은 PR과 테스트·이미지 검사를 요구한다. 이 저장소의 `main`도 PR을 요구하고(필수 상태 검사는 `validate`),
  사람은 이 룰셋 때문에 prod를 PR로만 바꿀 수 있다. 앱 저장소 CI가 쓰는 deploy key는 이 룰셋을 우회(bypass)하도록 등록해서 dev 이미지 태그를 직접 커밋하게 한다.
  다만 우회는 저장소 전체에 미치므로 기술적으로는 이 키로 prod 파일도 직접 커밋할 수 있다. prod가 그대로인 것은 룰셋이 막아서가 아니라
  CI 스크립트가 dev 파일만 고치기 때문이다(GitHub 룰셋은 저장소 설정에 있고 이 저장소의 파일에는 없다).
- **앱 이력과 배포 이력이 섞이지 않는다.** 배포마다 생기는 태그 커밋이 앱 저장소 로그에 끼어들면 기능 변경을 찾는 `git log`·`git blame`·`git bisect`가 배포 커밋으로 어수선해진다.
  반대로 앱 코드 커밋이 이 저장소에 끼어들면 "무엇이 언제 배포됐나"가 흐려진다.
- **"태그 커밋이 CI를 다시 돌린다"는 이유는 아니다.** 흔히 앱 CI가 배포 태그를 앱 저장소 `main`에 커밋하면 그 푸시가 다시 CI를 돌려 고리가 생긴다고 하지만, 늘 그런 것은 아니다.
  워크플로의 `GITHUB_TOKEN`으로 한 푸시는 새 워크플로 실행을 시작시키지 않는다(GitHub가 재귀 실행을 막으려고 정한 규칙이다. `workflow_dispatch`·`repository_dispatch` 등 몇 가지만 예외:
  GitHub 문서의 "Triggering a workflow from a workflow"). 고리가 생기는 것은 워크플로를 시작시키는 자격 증명(개인 액세스 토큰, deploy key, GitHub App 토큰)으로 푸시할 때이고,
  PR을 요구하는 보호된 `main`에 직접 커밋하려면 룰셋을 우회할 수 있는 그런 자격 증명이 필요하다. 그때는 paths 필터 같은 별도 장치로 고리를 끊어야 한다.
  분리한 진짜 이유는 위의 배포 이력, 권한 분리, 이력 분리다.
- **ArgoCD가 배포와 무관한 커밋에 반응하지 않는다.** ArgoCD는 `main`이 가리키는 커밋이 바뀌면 그 커밋으로 매니페스트를 다시 만든다.
  앱 코드 커밋이 잦은 저장소를 읽으면 배포와 무관한 커밋마다 렌더링이 다시 돈다(Application에 `manifest-generate-paths` 어노테이션을 달면 줄일 수는 있다).

## 구성

```
charts/shortener/                Helm 차트: 앱 + 클러스터 안의 PostgreSQL·Redis (앱 저장소의 deploy/helm/shortener를 옮겨 온 것)
environments/dev/values.yaml     dev 값. image.tag는 앱 저장소 CI가 고친다
environments/prod/values.yaml    prod 값. image.tag는 사람이 PR로 바꾼다(승격)
clusters/local/k3d.yaml          로컬 k3d 클러스터 정의 (맥의 8090 포트 → Traefik 80). 그 클러스터는 지금 멈춰 두었다
bootstrap/argocd/values.yaml     ArgoCD를 처음 설치할 때 쓰는 Helm 값 (최소 구성)
argocd/root.yaml                 app-of-apps 루트 Application. ArgoCD를 설치한 뒤 손으로 한 번만 적용한다
argocd/apps/shortener-dev.yaml   dev Application
argocd/apps/shortener-prod.yaml  prod Application
argocd/apps/kube-prometheus-stack.yaml      모니터링 Application (외부 차트 + 이 저장소의 값, multi-source)
platform/kube-prometheus-stack/values.yaml  그 값 (Prometheus·Alertmanager·Grafana. 아래 "모니터링")
tests/slo/                       앱 SLO 규칙(차트의 PrometheusRule)의 promtool 단위 테스트. validate가 차트를 렌더링해 꺼낸 규칙으로 돌린다
.github/workflows/validate.yml   PR·main 푸시 검증 (값 파일 형식, helm lint, 렌더링, 스키마 검사, SLO 규칙 검사, 플랫폼 차트 렌더링)
.github/dependabot.yml           GitHub Actions 주간 갱신
```

| | dev | prod |
|---|---|---|
| 네임스페이스 | `shortener-dev` | `shortener-prod` |
| 주소 | http://dev.dev-ops-study.duckdns.org | http://dev-ops-study.duckdns.org |
| 이미지 태그를 바꾸는 방법 | 앱 저장소 CI가 자동으로 커밋 | 사람이 PR로 승격 |
| 파드 | 1개 고정 | HPA가 1~3개로 조절 (아래 메모리 메모) |
| 앱 메모리 요청 / 한도 | 384Mi / 512Mi | 384Mi / 512Mi |
| ArgoCD Application | `shortener-dev` | `shortener-prod` |

- 클러스터는 EC2 `m7i-flex.large`(2 vCPU, 메모리 8GiB, ap-northeast-2) 한 대의 k3s다. dev·prod 두 환경과 ArgoCD가 이 노드 하나를 나눠 쓴다.
  로컬 k3d 클러스터는 Docker VM(2.84GiB)의 메모리가 dev 롤링 업데이트 중에 모자라서 프로젝트를 옮기고 멈춰 두었다(아래 메모리 메모).
- 주소는 DuckDNS 이름 `dev-ops-study`다. DuckDNS가 그 아래의 하위 이름도 같은 IP로 해석하므로 dev 주소(`dev.dev-ops-study.duckdns.org`)는 따로 등록하지 않는다.
  두 주소가 같은 노드의 80 포트로 들어오고, Traefik이 Host 헤더로 dev와 prod를 나눈다. 지금은 평문 HTTP(80)뿐이다(HTTPS는 나중에 cert-manager로 붙인다).
- DB 비밀번호 Secret `shortener-db`(키 `password`)는 **Git에 없다.** 각 네임스페이스에 손으로 만든다(아래 부트스트랩).
- 리소스 이름은 ArgoCD가 Application 이름을 Helm 릴리스 이름으로 쓰기 때문에 `shortener-dev`, `shortener-dev-postgresql`, `shortener-dev-redis`처럼 환경 이름으로 시작한다(prod도 같다).
- ArgoCD는 Helm을 `helm template`으로 렌더링하는 도구로만 쓴다. Helm 릴리스를 만들지 않으므로 `helm ls`에 보이지 않고 `helm rollback`·`helm test`는 쓸 수 없다
  ([ArgoCD FAQ](https://argo-cd.readthedocs.io/en/stable/faq/#after-deploying-my-helm-application-with-argo-cd-i-cannot-see-it-with-helm-ls-and-other-helm-commands)).

## 배포는 이렇게 일어난다

```
앱 저장소 PR 머지 → CI(test, image) 통과 → deploy-dev 잡이 이 저장소 environments/dev/values.yaml의 image.tag를 새 커밋 SHA로 바꿔 main에 커밋
  → ArgoCD가 폴링으로 그 커밋을 발견(bootstrap/argocd/values.yaml의 timeout.reconciliation: 60s)
  → shortener-dev Application이 자동 동기화 → Deployment 롤링 업데이트(새 파드가 Ready가 된 뒤에 옛 파드가 내려간다)
```

- ArgoCD를 Ingress로 열지 않아서(EC2에서는 port-forward로만 본다. 아래 "ArgoCD UI") GitHub 웹훅이 닿을 곳이 없다. 그래서 ArgoCD의 **폴링**만 변경을 알아채는 수단이다. 확인 주기는 60초로 줄였지만(기본은 최대 3분), ArgoCD의 repo-server도 같은 값을
  "main이 가리키는 커밋" 조회 결과의 캐시 시간으로 쓴다. 그래서 커밋 후 반영까지 60초 안팎에서, 확인 시점과 캐시 만료가 어긋나면 2분 가까이 걸릴 수 있다.
- 기다리지 않고 바로 확인시키려면 Application을 새로고침한다(UI의 Refresh 버튼, 또는 아래 명령. 컨트롤러가 새로고침을 처리하고 나면 이 어노테이션을 지운다).
  ```bash
  kubectl -n argocd annotate application shortener-dev argocd.argoproj.io/refresh=normal --overwrite
  ```
- 파드마다 실제로 어느 커밋이 떠 있는지는 레이블에 있다: `kubectl -n shortener-dev get pods -L app.kubernetes.io/version`.

## 승격: dev에서 prod로

prod의 이미지 태그는 사람이 PR로 바꾼다(룰셋이 사람의 `main` 직접 푸시를 막는다). dev에서 확인한 SHA를 prod 파일에 그대로 옮기는 PR이다(`yq`가 필요하다: `brew install yq`. 없으면 값을 손으로 옮겨도 된다).
`yq` 식은 CI가 dev 태그를 고칠 때와 같은 `strenv` 형태다(이유는 아래 "이 저장소를 고칠 때 지킬 것").

```bash
git switch main && git pull
export SHA=$(yq '.image.tag' environments/dev/values.yaml)
git switch -c "promote/prod-${SHA:0:7}"
yq -i '.image.tag = strenv(SHA)' environments/prod/values.yaml
git diff                                   # 태그 한 줄만 바뀌어야 한다
git commit -am "deploy(prod): shortener ${SHA:0:7}"
git push -u origin HEAD
gh pr create --fill
```

PR은 `validate` 검사(룰셋 "PR 필수"의 필수 상태 검사)가 통과해야 머지된다. 머지하면 ArgoCD가 다음 폴링에서 prod에 반영한다. 승격의 관문은 이미지 태그에만 있다는 점에 유의한다:
`charts/shortener`의 템플릿이나 기본값을 고치면 dev와 prod가 같은 `main`을 읽으므로 **머지되는 순간 두 환경에 함께 반영된다.**

## 롤백

Git에서 배포 커밋을 되돌린다. 태그가 이전 값으로 돌아가는 새 커밋이 생기고(이력은 지우지 않는다) ArgoCD가 그것을 새 배포로 반영한다.

```bash
git switch main && git pull
git log --oneline -- environments/prod/values.yaml     # 되돌릴 배포 커밋 찾기 (dev는 environments/dev/values.yaml)
git switch -c revert/<이름>
git revert <커밋 SHA>
git push -u origin HEAD
gh pr create --fill
```

- 되돌린 태그의 이미지가 GHCR에 있어야 한다. 이미지 태그는 커밋 SHA라서 지우지 않는 한 남아 있다.
- dev는 다음 앱 `main` 푸시에서 CI가 태그를 다시 최신 SHA로 올린다. 문제가 앱 `main`에 있으면 그쪽도 함께 되돌려야 dev가 계속 옛 버전에 머문다.
- ArgoCD UI의 Rollback은 쓰지 않는다: 자동 동기화가 켜진 Application에는 롤백을 할 수 없다([ArgoCD 문서](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/#automated-sync-semantics)).
  자동 동기화를 끄고 롤백하면 클러스터가 Git과 어긋난 채 남는다. Git이 원본이라는 원칙에 맞는 롤백은 `git revert`다.

## 처음부터 띄우기 (부트스트랩)

필요한 것: kubectl, Helm 4, 그리고 클러스터. 지금 클러스터는 EC2의 k3s다(Docker와 k3d는 1번으로 로컬 k3d를 띄울 때만 필요하다). 이 저장소가 GitHub(공개)에 올라가 있어야 한다. 공개 저장소라서 ArgoCD에 저장소 자격 증명을 등록하지 않아도 읽힌다.

```bash
# 1. 로컬 k3d 클러스터 (맥의 8090 포트 → Traefik 80). EC2의 k3s에는 이미 있으므로 건너뛴다
k3d cluster create --config clusters/local/k3d.yaml

# 2. ArgoCD 설치 (차트 버전을 고정한다. 아래 "ArgoCD" 절 참고)
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
helm upgrade --install argocd argo/argo-cd --version 10.9.4 \
  -n argocd --create-namespace -f bootstrap/argocd/values.yaml --wait --timeout 10m

# 3. 네임스페이스와 DB 비밀번호 Secret (비밀번호는 Git에 넣지 않고 클러스터에만 둔다. 환경마다 다른 값이 만들어진다)
for env in dev prod; do
  kubectl create namespace shortener-$env
  kubectl -n shortener-$env create secret generic shortener-db --from-literal=password="$(openssl rand -base64 24)"
done

# 3-1. 모니터링 Secret 두 개. 이름과 키는 platform/kube-prometheus-stack/values.yaml이 정한다:
#      grafana-admin(키 admin-user, admin-password), alertmanager-discord(키 webhook-url).
#      EC2에서는 부트스트랩 스크립트가 만든다(웹훅은 SSM 파라미터 /dev-ops-study/discord-webhook-url의 값). 손으로 만들 때는 비밀번호를 무작위로 두고,
#      웹훅은 실제 주소 대신 가짜 주소로 둔다(Alertmanager는 뜨고 Discord 알림만 실패한다). 비밀번호는 파이프로 넘긴다(명령줄 인자는 ps로 보인다)
kubectl create namespace monitoring
openssl rand -hex 16 | tr -d '\n' | kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-file=admin-password=/dev/stdin
kubectl -n monitoring create secret generic alertmanager-discord --from-literal=webhook-url=https://discord.invalid/webhook-not-configured

# 4. 루트 Application 적용: 여기서부터 ArgoCD가 argocd/apps를 읽어 dev·prod와 모니터링을 만든다 (손으로 하는 마지막 단계)
kubectl apply -f argocd/root.yaml
```

- 2번은 ArgoCD 이미지(약 200MB)를 처음 내려받아서 몇 분 걸린다. 진행은 `kubectl -n argocd get pods`로 본다.
- 3번에서 네임스페이스를 미리 만드는 것은 Secret을 먼저 넣으려는 것이다. Application의 `CreateNamespace=true`는 이미 있는 네임스페이스를 건드리지 않는다.
  Secret이 없으면 앱·PostgreSQL 파드가 `CreateContainerConfigError`로 멈춰 있다가 Secret이 생기면 시작한다.
- 3-1의 Secret도 같다. `grafana-admin`이 없으면 Grafana 파드가 `CreateContainerConfigError`(환경 변수로 읽는다), `alertmanager-discord`가 없으면
  Alertmanager 파드가 `ContainerCreating`(볼륨으로 붙인다)에 머문다. EC2에서는 부트스트랩 스크립트가 루트 Application보다 먼저 만든다(`infra/aws/README.md`).
- 모니터링(kube-prometheus-stack, 메모리 요청만 약 1GiB)은 EC2 클러스터(메모리 8GiB)를 위한 것이다. 로컬 k3d의 Docker VM(2.84GiB)은 앱만으로도 메모리가 모자라
  EC2로 옮겼으므로(아래 메모리 메모) 그 위에는 자리가 없다. 루트 Application은 argocd/apps를 모두 배포하므로 로컬 k3d에서도 모니터링 Application이 생긴다.
  그래도 로컬에서 띄운다면 3-1의 두 Secret을 위처럼 무작위 비밀번호와 가짜 웹훅 주소로 만든다.
- 로컬 k3d에 이전 단계에서 `helm install`로 직접 설치한 `shortener` 릴리스(`shortener` 네임스페이스)가 남아 있으면 먼저 지운다. 로컬용으로 덮어쓴 prod 호스트(`shortener.localhost`)와
  같은 호스트를 쓰는 Ingress가 둘이 되면 요청이 어느 쪽으로 갈지 보장되지 않는다. EC2에는 그런 릴리스가 없다.

확인:

```bash
kubectl -n argocd get applications          # root, shortener-dev, shortener-prod, kube-prometheus-stack이 Synced·Healthy가 될 때까지 몇 분 걸린다
kubectl -n shortener-dev get pods
kubectl -n shortener-prod get pods
kubectl -n monitoring get pods              # 아래 "모니터링"의 파드 6개
curl -i -X POST http://dev.dev-ops-study.duckdns.org/api/v1/urls -H 'Content-Type: application/json' -d '{"url": "https://example.com"}'
curl -i -X POST http://dev-ops-study.duckdns.org/api/v1/urls     -H 'Content-Type: application/json' -d '{"url": "https://example.com"}'
```

첫 배포에서 앱이 DB보다 먼저 뜨면 몇 번 재시작한 뒤 자리를 잡는다(정상).

**ArgoCD UI**: EC2에서는 Ingress로 열지 않고 port-forward로 본다(`server.insecure: true`라 UI가 평문 HTTP이기 때문이다). `kubectl -n argocd port-forward svc/argocd-server 8080:80` 뒤 http://localhost:8080 , 사용자 `admin`.
초기 비밀번호는 ArgoCD 서버가 처음 시작할 때 Secret에 만들어 둔다. (로컬 k3d에서는 Ingress로 http://argocd.localhost:8090 이다.)

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

(argocd CLI는 쓰지 않는다. 인터넷에 열지 않는 UI라서 이 비밀번호를 그대로 쓴다. 비밀번호를 바꿨다면 이 Secret은 지워도 된다.)

`bootstrap/argocd/values.yaml`은 로컬 k3d용이라 아직 ArgoCD의 Ingress(`argocd.localhost`)를 켜 둔다. EC2에 설치할 때는 위 2번 명령에 `--set server.ingress.enabled=false`를 더하고, 업그레이드 때도 같은 옵션을 다시 준다.
옵션이 빠지면 Ingress가 생기고, Host 헤더만 `argocd.localhost`로 맞추면 누구나 80 포트로 로그인 화면에 닿는다.

## ArgoCD

| 항목 | 값 |
|---|---|
| Helm 차트 | `argo/argo-cd` **10.9.4** |
| ArgoCD 앱 버전 | **v3.5.3** |
| 고른 방법 | 2026-09-30에 `helm repo add argo https://argoproj.github.io/argo-helm` 후 `helm search repo argo/argo-cd --versions`의 맨 위(정식 버전 중 최신) |
| repo-server가 쓰는 Helm | 4.2.1 (ArgoCD 저장소의 `hack/tool-versions.sh`). 로컬·CI의 Helm 4.3.0과 이 차트를 렌더링해 비교하면 문서 사이의 빈 줄 하나만 다르다 |
| 이미지 | `quay.io/argoproj/argocd:v3.5.3`, `ecr-public.aws.com/docker/library/redis:8.6.4-alpine` (둘 다 arm64·amd64 지원) |

이미지는 차트 버전이 정하는 태그를 그대로 쓴다. 값 파일에서 이미지 태그를 따로 고정하면 차트 버전을 올릴 때 앱 버전과 CRD가 어긋날 수 있어서 고정하지 않았다.
버전을 올릴 때는 `bootstrap/argocd/values.yaml`·이 README·설치 명령의 `--version`을 함께 바꾸고, 차트 README의 변경 이력(특히 메이저 버전)을 읽는다.

떠 있는 컴포넌트는 파드 1개씩 넷이다.

| 컴포넌트 | CPU 요청 | 메모리 요청 | 메모리 한도 |
|---|---|---|---|
| application-controller (StatefulSet) | 50m | 128Mi | 512Mi |
| repo-server | 25m | 96Mi | 512Mi |
| server | 25m | 64Mi | 192Mi |
| redis | 10m | 16Mi | 64Mi |
| **합계** | **110m** | **304Mi** | **1280Mi** |

- application-controller·repo-server의 메모리 한도는 4단계에서 256Mi에서 512Mi로 올렸다. kube-prometheus-stack은 CRD가 커서(가장 큰 것이 JSON으로 약 486KiB)
  컨트롤러가 캐시에 들고 있는 양이 늘고, repo-server 안에서 도는 `helm pull`·`helm template`이 이 차트에서 최대 RSS를 각각 195MiB·134MiB까지 쓴다(로컬에서 잰 값과 계산은 `bootstrap/argocd/values.yaml`).
  EC2에서는 부트스트랩이 ArgoCD가 이미 설치돼 있으면 건너뛰므로, 이 값은 인스턴스를 새로 만들 때 적용된다. 떠 있는 클러스터에 바로 넣으려면
  부트스트랩 2번의 `helm upgrade --install`을 다시 돌린다(EC2에서는 위에 적은 대로 `--set server.ingress.enabled=false`도 함께 준다).

끈 컴포넌트:

- **dex**: 없다(파드·리소스 모두). 외부 계정 로그인(SSO)용인데 로컬 admin 로그인만 쓴다.
- **notifications**: 없다(파드·리소스 모두). 동기화 결과를 보낼 곳이 없다.
- **applicationset**: Deployment는 있지만 `replicas: 0`이라 파드가 없다. 이 차트에는 ApplicationSet 컨트롤러를 끄는 스위치가 없고 항상 만들기 때문이다(차트 6.9.0부터, 차트 README의 변경 이력).
  Application을 손으로 적는 이 저장소에서는 쓸 일이 없고, 파드가 없어 메모리를 쓰지 않는다.

- CPU 한도는 두지 않는다(앱 차트와 같은 이유: CFS 쿼터 스로틀링). 위 값은 클러스터에서 측정한 것이 아니라 작은 규모를 가정한 추정이다. 띄운 뒤 `kubectl top pods -n argocd`로 확인한다.
- 설치·업그레이드 때만 도는 것이 따로 있다: redis 비밀번호 Secret을 만드는 Job(`redis-secret-init`, 끝나면 60초 뒤 지워진다)과 repo-server의 초기화 컨테이너(`copyutil`).
- `server.insecure: true`: TLS를 끝내는 곳이 없어서 서버가 평문 HTTP로만 받는 구성이다(로컬 k3d에서는 브라우저 → Traefik → 서버가 모두 평문 HTTP). 그래서 인터넷에 공개하면 안 되고, EC2에서는 Ingress 없이 port-forward로만 본다.
- ArgoCD 자신은 이 저장소의 Application으로 관리하지 않는다. 설치·업그레이드는 위 `helm upgrade --install` 명령으로 한다.

### `helm.sh/hook: test` 파드는 어떻게 되나

차트의 `templates/tests/test-readiness.yaml`은 `helm.sh/hook: test` 파드다(`helm test`가 readiness 엔드포인트를 확인한다). **ArgoCD는 이 파드를 만들지도 실행하지도 않고 건너뛴다.**

- 근거(문서): ArgoCD 사용자 가이드 Helm 절 — "Argo CD currently skips manifests that include hooks not supported by Argo CD, including Helm test hooks."
- 근거(소스, ArgoCD v3.5.3의 `gitops-engine/pkg/sync`): `helm.sh/hook` 어노테이션이 있으면(`crd-install` 제외) 훅으로 분류되어 일반 리소스 목록에서 빠진다(`hook.IsHook`, `reconcile.go`).
  그런데 동기화 단계로 대응되는 Helm 훅은 `pre-install`·`pre-upgrade`(PreSync)와 `post-install`·`post-upgrade`(PostSync)뿐이고(`hook/helm/type.go`. `pre-delete`·`post-delete`는 삭제 때 도는 훅으로 따로 처리한다),
  훅은 PreSync·Sync·PostSync·SyncFail 단계에서만 실행된다(`sync_phase.go`). `test`는 어느 단계에도 없어서 동기화 작업이 만들어지지 않는다.
  동기화 상태 비교에서도 훅은 제외된다(`controller/state.go`).
- 그래서 이 파드는 클러스터에 생기지 않고 Application의 Sync 상태에도 영향이 없다. 차트에는 남겨 두었다: 다른 클러스터에서 `helm install`로 직접 설치할 때 `helm test`로 쓸 수 있고,
  `helm template` 결과에는 들어가므로 CI의 스키마 검사(kubeconform)는 이 파드도 검사한다.
- ArgoCD로 배포한 앱의 배포 확인은 ArgoCD의 Application 상태(Synced·Healthy)와 위 `curl`로 한다. 앱의 readiness 엔드포인트를 직접 보려면
  `kubectl -n shortener-dev port-forward svc/shortener-dev 8081:8081` 뒤 `curl localhost:8081/actuator/health/readiness`.

## 모니터링 (kube-prometheus-stack)

Application `kube-prometheus-stack`이 Helm 차트 `prometheus-community/kube-prometheus-stack` **91.8.2**를 `platform/kube-prometheus-stack/values.yaml`의 값으로
`monitoring` 네임스페이스에 배포한다. 차트는 외부 차트 저장소에 있고 값만 이 저장소에 있어서 소스를 둘 쓴다(multi-source: 차트 + `ref: values`로 가리키는 이 저장소).
값을 바꾸는 방법은 앱과 같다: 값 파일을 고치는 PR을 머지하면 ArgoCD가 다음 폴링에서 반영한다. Grafana에는 Loki 데이터 소스(`uid: loki`)가 미리 들어 있다(Loki는 따로 배포한다).

| 파드 | 하는 일 | CPU 요청 | 메모리 요청 / 한도 |
|---|---|---|---|
| `prometheus-kube-prometheus-stack-prometheus-0` (Operator가 만드는 StatefulSet) | 지표 수집·저장, 규칙 평가 | 110m | 528Mi / 1088Mi |
| `alertmanager-kube-prometheus-stack-alertmanager-0` (Operator가 만드는 StatefulSet) | 경보를 묶어 Discord로 보낸다 | 20m | 48Mi / 192Mi |
| `kube-prometheus-stack-operator` | Prometheus·Alertmanager 리소스를 StatefulSet으로, ServiceMonitor·PrometheusRule을 Prometheus 설정으로 바꾼다 | 20m | 64Mi / 192Mi |
| `kube-prometheus-stack-grafana` | 대시보드. 사이드카 2개가 ConfigMap의 대시보드·데이터 소스를 넣는다 | 70m | 320Mi / 768Mi |
| `kube-prometheus-stack-kube-state-metrics` | 쿠버네티스 객체의 상태를 지표로 | 10m | 64Mi / 128Mi |
| `kube-prometheus-stack-prometheus-node-exporter` (DaemonSet) | 노드의 CPU·메모리·디스크 지표 | 10m | 32Mi / 64Mi |
| **합계** | | **240m** | **1056Mi / 2432Mi** |

파드별 값은 config-reloader·사이드카 같은 보조 컨테이너까지 더한 것이다. 클러스터에서 잰 값이 아니라 추정이라 띄운 뒤 `kubectl top pods -n monitoring`으로 확인한다.

### 열어 보기 (port-forward)

Ingress를 만들지 않는다. 80 포트는 인터넷에 열린 평문 HTTP라 Grafana 로그인 화면과 인증이 없는 Prometheus·Alertmanager의 UI·API를 그대로 내놓게 된다.
HTTPS를 붙이기 전(6단계)에는 ArgoCD UI처럼 맥에서 port-forward로만 본다(인터넷을 건너는 구간은 k3s API의 TLS뿐이다).

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80          # http://localhost:3000 (사용자 admin)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090     # http://localhost:9090 (Status → Target health, Alerts)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093   # http://localhost:9093
```

Grafana 관리자 비밀번호는 부트스트랩이 무작위로 만들어 Secret `grafana-admin`에 넣어 둔다. 이렇게 읽는다(화면에 찍히므로 화면 공유·녹화 중에는 쓰지 않는다):

```bash
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Grafana는 자기 DB를 PVC 없이 emptyDir에 둔다. 대시보드는 Git(레이블 `grafana_dashboard: "1"`이 붙은 `monitoring` 네임스페이스의 ConfigMap)에서, 데이터 소스는 차트가 만드는 ConfigMap에서 오므로
파드가 다시 떠도 그대로지만, UI에서 손으로 만들거나 고친 대시보드는 사라진다. 남길 대시보드는 JSON으로 내보내 이 저장소에 ConfigMap으로 넣는다.

### 경보가 가는 길

규칙(차트의 기본 규칙, 앱 차트의 SLO 규칙) → Prometheus가 30초마다 평가 → Alertmanager가 묶어서 수신자로 보낸다. 경로는 위에서부터 처음 맞는 하나만 탄다.

| 경보 | 가는 곳 |
|---|---|
| `Watchdog`(경보 파이프라인이 살아 있음을 보이려고 늘 울리는 경보), `InfoInhibitor`(info 경보를 누르는 데만 쓰는 경보. 같은 네임스페이스에 info 경보가 있고 warning·critical 경보는 울리지 않을 때만 울린다) | 보내지 않는다(`null`) |
| `service="shortener"` (앱의 SLO 경보) | Discord |
| `severity="critical"` (그 밖의 critical 경보) | Discord |
| 나머지(warning·info) | 보내지 않는다. Alertmanager UI에서 본다 |

- 같은 `alertname`·`namespace`의 경보를 한 알림으로 묶는다. 첫 알림은 30초 모았다 보내고, 묶음이 바뀌면 5분 간격으로, 그대로 울리면 4시간마다 다시 보낸다. 풀리면(RESOLVED)도 알린다.
- Discord 웹훅 주소는 Git에 없다. 부트스트랩이 SSM 파라미터 `/dev-ops-study/discord-webhook-url`의 값으로 Secret `alertmanager-discord`(키 `webhook-url`)를 만들고,
  Alertmanager가 그 파일(`/etc/alertmanager/secrets/alertmanager-discord/webhook-url`)을 알림을 보낼 때마다 읽는다. 주소를 바꾸는 방법은 `infra/aws/README.md`.
- 클러스터 없이 라우팅을 확인하는 방법은 아래 "로컬에서 검증하기"에 있다.

### k3s·ArgoCD 때문에 기본값에서 바꾼 것

- **k3s**: kube-controller-manager·kube-scheduler·kube-proxy는 파드가 아니라 k3s 프로세스 안에서 돌고, etcd는 없다(SQLite). 차트 기본값대로면 이것들을 수집하지 못해
  `KubeSchedulerDown` 같은 critical 경보가 영원히 울리므로 수집과 그 규칙을 끈다.
- **ServerSideApply=true**: 차트의 CRD 6개가 클라이언트 쪽 적용이 쓰는 `last-applied-configuration` 어노테이션의 한도(256KiB)보다 크다(가장 큰 prometheuses CRD가 JSON으로 약 486KiB).
- **어드미션 웹훅 끔**: 켜 두면 인증서를 만드는 Helm 훅 Job이 동기화마다 다시 돌고 웹훅 설정의 caBundle을 Git 밖에서 고쳐 쓴다. 그 인증서를 쓰는 Operator의 TLS도 함께 끈다.
- **Grafana 관리자 Secret은 부트스트랩이 만든다**: 차트가 만들게 두면 ArgoCD가 렌더링할 때마다 무작위 비밀번호가 새로 나와 늘 OutOfSync가 된다.
- **ServiceMonitor·PrometheusRule을 레이블 없이 모든 네임스페이스에서 고른다**(`*SelectorNilUsesHelmValues: false`): 앱 차트가 만드는 것에 이 릴리스의 `release` 레이블을 붙이지 않아도 된다.
- **보존 3일·4GB**(PVC 5Gi, local-path): 인스턴스를 공부하는 동안만 띄우고 없애서 30일 오류 예산을 셀 만큼 쌓이지 않는다. 그래서 SLO는 소진 속도(burn rate)와 1h·6h·1d 가용성으로 본다.
- **node-exporter도 hostNetwork 없이**: 노드의 네트워크를 같이 쓰는 파드는 IMDSv2의 홉 제한 1에 걸리지 않아 인스턴스 역할(SSM의 DuckDNS 토큰·Discord 웹훅 주소를 읽는다)을 얻을 수 있다.
  이 클러스터는 hostNetwork 파드를 띄우지 않는다(`infra/aws/README.md`). 대가는 네트워크 지표의 일부다: 송수신·오류 카운터(netdev 수집기, netlink)와 `/proc/net`을 읽는
  수집기(netstat·sockstat)는 노드가 아니라 그 파드의 네트워크(eth0, lo)를 보인다. 그래서 노드 트래픽 패널과 `NodeNetworkReceiveErrs`·`TransmitErrs`는 그 파드의 트래픽을 본다.
  인터페이스 상태(netclass 수집기: `node_network_up`·`_info`·`_mtu_bytes`·`_speed_bytes`·`_carrier` 등)는 노드의 sysfs(`/host/sys`)를 읽으므로 그대로 노드의 인터페이스이고,
  `NodeNetworkInterfaceFlapping`도 노드를 본다. CPU·메모리·디스크·파일시스템도 그대로다.
- 자세한 이유는 `platform/kube-prometheus-stack/values.yaml`과 `argocd/apps/kube-prometheus-stack.yaml`의 주석에 있다.

## 메모리 메모

노드는 EC2 `m7i-flex.large`(2 vCPU, 메모리 8GiB = 8192Mi) 한 대다. 로컬 Docker VM(2.84GiB)은 dev 롤링 업데이트 중에 메모리가 모자라서 프로젝트를 이 노드로 옮겼다.
8GiB에서는 앱 메모리를 줄일 이유가 없어 두 환경 모두 차트 기본값(요청 384Mi·한도 512Mi)으로 되돌렸고, prod의 HPA를 다시 켰다(파드 1~3개). dev는 파드 1개 고정이다.
JVM 최대 힙은 컨테이너 메모리 한도의 75%(앱 이미지의 `-XX:MaxRAMPercentage=75.0`)라서 한도 512Mi에서는 384Mi다.

| | 요청 합 | 한도 합 |
|---|---|---|
| k3s와 기본 구성요소 (Traefik 등. 사용량으로 잡은 값) | 약 800Mi | 약 800Mi |
| ArgoCD (파드 4개. 4단계에서 컨트롤러·repo-server 한도를 512Mi로 올렸다) | 304Mi | 1280Mi |
| 모니터링: kube-prometheus-stack (파드 6개, 위 "모니터링" 표) | 1056Mi | 2432Mi |
| dev (앱 384Mi/512Mi + PostgreSQL 128Mi/256Mi + Redis 32Mi/128Mi, 앱 1개) | 544Mi | 896Mi |
| prod, HPA가 최대 3개까지 늘었을 때 (앱 3개 + PostgreSQL 256Mi/512Mi로 키움 + Redis 32Mi/128Mi) | 1440Mi | 2176Mi |
| 합계 | 4144Mi | 7584Mi |
| 롤링 업데이트 중 환경마다 앱 파드 하나 추가 (maxSurge 1) | +384Mi | +512Mi |
| 합계, 두 환경이 동시에 롤링 중일 때 | 4912Mi | 8608Mi |

- **요청 합은 최악에도 노드 안에 든다.** 요청은 스케줄러가 자리를 계산하는 값이다. prod가 3개인 채 두 환경이 동시에 롤링해도(차트의 파드 템플릿을 고치면 두 환경이 같은 `main`의 차트를 읽어 동시에 롤링된다)
  4912Mi로 8192Mi(실제 MemTotal은 약 7.6GiB)보다 작다. 4단계에서 새로 더하는 요청은 약 1.6GiB까지로 잡았고, 그중 kube-prometheus-stack이 1056Mi를 쓴다. 남은 약 580Mi가 Loki·Alloy 몫이다.
- **한도 합은 최악에 노드 메모리를 넘는다(오버커밋).** 3단계까지는 모든 컨테이너가 한도까지 쓰는 최악(5664Mi)도 노드 안에 들게 잡았지만, 모니터링과 ArgoCD 한도를 더하니 8608Mi로 넘는다.
  모든 컨테이너가 한꺼번에 한도까지 쓰는 일은 드물다고 보고 받아들인다. 한도는 컨테이너 하나가 폭주할 때 그 컨테이너만 OOMKilled로 멈추게 하는 상한이다.
  한도보다 노드가 먼저 모자라면 kubelet이 요청을 넘게 쓰는 파드부터 내쫓는다(그래서 요청을 평소 사용량 가까이 잡는다). 띄운 뒤 실제 사용량으로 다시 본다.
- 위 합계는 추정이다. k3s 행의 약 800Mi는 로컬 k3d의 빈 클러스터에서 잰 약 770MiB를 올려 잡은 값이고 EC2에서는 재지 않았다. 8GiB는 명목 크기라 실제 MemTotal은 조금 작고 호스트 OS도 메모리를 쓰므로 그만큼 위 여유가 줄어든다.
  한도는 상한일 뿐 평소 사용량은 훨씬 작다: 2단계에서 한도 512Mi로 띄웠을 때 유휴 상태의 앱 파드는 약 320Mi, PostgreSQL은 약 55Mi, Redis는 약 15Mi였다(`kubectl top`). 띄운 뒤 실제 값을 확인한다: `kubectl top pods -A --sort-by=memory`, 노드에서 `free -m`.
- **prod가 최대 3개까지 늘 수 있다고 보고 예산을 잡았다.** 2단계에서는 새 파드가 뜬 직후 HPA가 앱을 1개에서 2개로 늘렸다가 5분쯤 뒤에 줄이는 일이 여러 번 있었다(콜드 JVM의 CPU 급증 때문으로 추정하지만 그 순간의 CPU는 재지 않았다).
  HPA 자체는 2단계에서 이미 연습했다. 차트의 기본값(HPA 1~2개)은 그대로 두었고 prod의 환경 값 파일이 최대를 3개로 덮어쓴다.
  메모리 말고 DB 커넥션도 파드 수를 받쳐 줘야 한다: 앱 파드가 커넥션을 10개씩 잡아 최대 4개(3개 + 롤링 업데이트 중 1개)면 40개인데 차트 PostgreSQL의 `max_connections`는 30이다.
  그래서 prod의 PostgreSQL만 `max_connections`를 60으로, 메모리를 요청 256Mi·한도 512Mi로 키웠다(dev는 파드 1개 + 롤링 1개 = 20개라 차트 기본값 그대로다. 계산은 `environments/prod/values.yaml`의 `postgresql` 위 주석).
- **로컬 k3d(`devops-study`)는 멈춰 두었다**(`k3d cluster stop devops-study`. 데이터는 남는다). 다시 켜면(`k3d cluster start devops-study`) 그 안의 ArgoCD가 `main`의 값(EC2 주소와 크기)으로 맞추려 하므로, 로컬에서 쓰려면 먼저 두 환경 값 파일을 덮어써야 한다:
  `baseUrl`·`ingress.host`는 `*.localhost` 이름(예전 값: `shortener-dev.localhost:8090`, `shortener.localhost:8090`)으로, 앱 메모리·HPA는 2.84GiB VM에 맞춘 예전 크기(앱 요청 256Mi·한도 384Mi, 두 환경 모두 파드 1개 고정)로. 예전 값은 `git log -p -- environments/`에 있다.
- dev를 잠시 끄고 싶다면 `kubectl scale`이 아니라 Git에서 `environments/dev/values.yaml`의 `replicaCount`를 0으로 바꾼다. dev는 HPA가 없어 selfHeal이 손으로 바꾼 파드 수를 되돌리기 때문이다.
  prod는 HPA가 켜져 있어 `replicaCount`가 쓰이지 않는다: 끄려면 `autoscaling.enabled`를 false로 바꾸고 `replicaCount: 0`을 적는다.
- OOMKilled(exit 137)가 보이면 그 컨테이너의 메모리 한도를 올린다. ArgoCD는 `bootstrap/argocd/values.yaml`을 고치고 `helm upgrade --install`을 다시 실행한다(EC2에서는 `--set server.ingress.enabled=false`도 다시 준다).
  앱은 `environments/<환경>/values.yaml`의 `resources.limits.memory`를 고친다. 한도를 올리면 힙 상한도 한도의 75%로 따라 오른다.

## 로컬에서 검증하기

CI(`validate.yml`)가 하는 일을 클러스터 없이 그대로 해 볼 수 있다. 값(kubeconform 이미지, 스키마 위치)은 `validate.yml`의 것을 읽어 쓴다(`yq` 필요).

```bash
KUBERNETES_VERSION=$(yq '.jobs.validate.env.KUBERNETES_VERSION' .github/workflows/validate.yml)
KUBECONFORM_IMAGE=$(yq '.jobs.validate.env.KUBECONFORM_IMAGE' .github/workflows/validate.yml)
K8S_SCHEMA_LOCATION=$(yq '.jobs.validate.env.K8S_SCHEMA_LOCATION' .github/workflows/validate.yml)
CRD_SCHEMA_LOCATION=$(yq '.jobs.validate.env.CRD_SCHEMA_LOCATION' .github/workflows/validate.yml)
PROMETHEUS_IMAGE=$(yq '.jobs.validate.steps[] | select(.env.PROMETHEUS_IMAGE) | .env.PROMETHEUS_IMAGE' .github/workflows/validate.yml)
out=$(mktemp -d)

mkdir -p tests/slo/rendered     # 렌더링해서 꺼낸 SLO 규칙을 둘 곳(.gitignore에 있다)
for env in dev prod; do
  diff <(yq '.' environments/$env/values.yaml) environments/$env/values.yaml     # 값 파일이 yq가 쓰는 모양인가 (출력이 없어야 한다)
  helm lint charts/shortener --strict --kube-version $KUBERNETES_VERSION -f environments/$env/values.yaml
  # --api-versions: 모니터링 CRD가 있는 클러스터처럼 렌더링해서 ServiceMonitor·PrometheusRule도 나오게 한다(ArgoCD는 클러스터의 API 목록을 넘긴다)
  helm template shortener-$env charts/shortener --namespace shortener-$env --kube-version $KUBERNETES_VERSION \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor --api-versions monitoring.coreos.com/v1/PrometheusRule \
    -f environments/$env/values.yaml > $out/shortener-$env.yaml
  docker run -i --rm $KUBECONFORM_IMAGE -strict -summary -schema-location "$K8S_SCHEMA_LOCATION" -schema-location "$CRD_SCHEMA_LOCATION" \
    -kubernetes-version $KUBERNETES_VERSION - < $out/shortener-$env.yaml
  yq 'select(.kind == "PrometheusRule") | .spec' $out/shortener-$env.yaml > tests/slo/rendered/shortener-$env.yaml
done

# SLO 규칙: promtool로 문법을 검사하고 단위 테스트(tests/slo/shortener-slo.test.yaml)를 돌린다
docker run --rm -v "$PWD/tests/slo:/slo:ro" --entrypoint /bin/promtool "$PROMETHEUS_IMAGE" \
  check rules --lint-fatal /slo/rendered/shortener-dev.yaml /slo/rendered/shortener-prod.yaml
docker run --rm -v "$PWD/tests/slo:/slo:ro" --entrypoint /bin/promtool "$PROMETHEUS_IMAGE" test rules /slo/shortener-slo.test.yaml

docker run --rm -v "$PWD":/work:ro -w /work $KUBECONFORM_IMAGE -strict -summary \
  -schema-location "$K8S_SCHEMA_LOCATION" -schema-location "$CRD_SCHEMA_LOCATION" -kubernetes-version $KUBERNETES_VERSION argocd/
```

`helm template`은 ArgoCD가 하는 것과 같이 릴리스 이름(`shortener-dev`)과 네임스페이스를 주고 환경 값 파일을 얹어 렌더링한다. `image.tag`가 커밋 SHA 40자가 아니거나 DB Secret 이름이 없으면
차트가 안내 메시지와 함께 실패한다. `helm lint`에는 `--api-versions` 옵션이 없어서 ServiceMonitor·PrometheusRule은 lint에서 렌더링되지 않는다(내용은 렌더링·kubeconform·promtool이 검사한다).
SLO 규칙 테스트의 시나리오와 읽는 법은 `tests/slo/shortener-slo.test.yaml`의 머리말에 있다. 워크플로 파일은 `docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.12`로 검사한다.

플랫폼 차트(argocd/apps에서 `chart:` 소스를 쓰는 Application. 지금은 kube-prometheus-stack)는 CI 단계의 스크립트를 그대로 꺼내 돌린다.
GitHub가 넣어 주는 변수 셋(`GITHUB_SERVER_URL`, `GITHUB_REPOSITORY`, `RUNNER_TEMP`)은 대신 준다. 위에서 읽은 변수를 그대로 쓴다:

```bash
export KUBERNETES_VERSION KUBECONFORM_IMAGE K8S_SCHEMA_LOCATION CRD_SCHEMA_LOCATION
step='.jobs.validate.steps[] | select(.env.K8S_LOCAL_SCHEMA_LOCATION)'
export K8S_LOCAL_SCHEMA_LOCATION=$(yq "$step | .env.K8S_LOCAL_SCHEMA_LOCATION" .github/workflows/validate.yml)
GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=seongj-un/dev-ops-study-config RUNNER_TEMP=$(mktemp -d) \
  bash -c "$(yq "$step | .run" .github/workflows/validate.yml)"
```

렌더링 결과를 직접 보려면 `helm template kube-prometheus-stack kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version 91.8.2 -n monitoring --include-crds -f platform/kube-prometheus-stack/values.yaml`이다.
Alertmanager 설정은 그 결과의 Secret에서 꺼내 `amtool`로 문법과 라우팅을 확인한다(이미지 태그는 차트가 쓰는 Alertmanager 버전과 같게 둔다):

```bash
am=$(mktemp -d)/alertmanager.yaml
helm template kube-prometheus-stack kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version 91.8.2 \
    -n monitoring -f platform/kube-prometheus-stack/values.yaml \
  | yq 'select(.kind == "Secret" and .metadata.name == "alertmanager-kube-prometheus-stack-alertmanager") | .data."alertmanager.yaml"' \
  | base64 -d > $am
amtool() { docker run --rm -v $am:/c.yaml:ro --entrypoint amtool quay.io/prometheus/alertmanager:v0.34.1 "$@"; }
amtool check-config /c.yaml
amtool config routes show --config.file=/c.yaml
amtool config routes test --config.file=/c.yaml alertname=X service=shortener severity=critical   # discord
amtool config routes test --config.file=/c.yaml alertname=Watchdog severity=none                  # null
```

ArgoCD 설치 값은 이렇게 확인한다. 워크로드는 dex·notifications 없이 다섯 개(applicationset만 replicas 0)이고, Ingress는 Traefik으로 `argocd.localhost`여야 한다:

```bash
helm template argocd argo/argo-cd --version 10.9.4 -n argocd -f bootstrap/argocd/values.yaml \
  | yq -N 'select(.kind == "Deployment" or .kind == "StatefulSet") | .metadata.name + " replicas=" + (.spec.replicas | tostring)'
helm template argocd argo/argo-cd --version 10.9.4 -n argocd -f bootstrap/argocd/values.yaml \
  | yq -N 'select(.kind == "Ingress") | .spec.ingressClassName + " " + .spec.rules[0].host'
```

## 고정한 버전

| 대상 | 버전 | 어디에 |
|---|---|---|
| ArgoCD Helm 차트 / 앱 | 10.9.4 / v3.5.3 | `bootstrap/argocd/values.yaml`, 이 README |
| Helm (로컬·CI) | 4.3.0 | `validate.yml`의 `azure/setup-helm` 입력 `version` |
| `actions/checkout` | v7.0.1 (커밋 SHA로 고정) | `validate.yml` |
| `azure/setup-helm` | v5.0.1 (커밋 SHA로 고정) | `validate.yml` |
| kubeconform | v0.8.0 (태그@다이제스트) | `validate.yml`의 `KUBECONFORM_IMAGE` |
| 쿠버네티스 내장 리소스 스키마 | yannh/kubernetes-json-schema 커밋 `8df8a88`(2026-09-29의 최신 커밋) | `validate.yml`의 `K8S_SCHEMA_LOCATION` |
| CRD 스키마 (Argo CD, monitoring.coreos.com) | datreeio/CRDs-catalog 커밋 `d373c2d`(2026-09-29. Argo CD 3.5.0 CRD 기준. monitoring.coreos.com 스키마는 클러스터의 Prometheus Operator v0.94.1보다 오래됐다: `validate.yml`의 주석) | `validate.yml`의 `CRD_SCHEMA_LOCATION` |
| Prometheus (promtool) | v3.15.0 (태그@다이제스트. kube-prometheus-stack 91.8.2가 띄우는 Prometheus와 같은 버전) | `validate.yml` "SLO 규칙 검사" 단계의 `PROMETHEUS_IMAGE` |
| 검증 기준 쿠버네티스 | 1.35.0 (클러스터는 k3s v1.35.8) | `validate.yml`의 `KUBERNETES_VERSION`, `clusters/local/k3d.yaml` |
| kube-prometheus-stack 차트 | 91.8.2 (Prometheus Operator v0.94.1. 이미지 태그도 이 차트 버전이 정한다) | `argocd/apps/kube-prometheus-stack.yaml`의 `targetRevision`, 값 파일 맨 위 주석, 이 README |
| CustomResourceDefinition 객체의 스키마 | yannh/kubernetes-json-schema 커밋 `8df8a88`의 `-local` 디렉터리 (`-standalone`에는 없다) | `validate.yml` 플랫폼 차트 단계의 `K8S_LOCAL_SCHEMA_LOCATION` |

액션은 Dependabot이 SHA와 버전 주석을 함께 올려 준다. 나머지는 손으로 올린다(`.github/dependabot.yml` 참고).

## 이 저장소를 고칠 때 지킬 것

- `environments/dev/values.yaml`의 `image.tag`는 `image:` 아래 한 줄로 둔다. 앱 저장소 CI(`deploy-dev` 잡)가 커밋 SHA를 환경 변수 `IMAGE_TAG`로 주고
  `yq -i '.image.tag = strenv(IMAGE_TAG)' environments/dev/values.yaml`로 고친다. `strenv`를 쓰는 이유: 값이 yq 식에 글자로 끼워 넣어지지 않고 환경 변수로 들어가며 항상 문자열로 남는다
  (`env()`는 값을 YAML로 해석해서 숫자처럼 생긴 값을 숫자로 읽을 수 있다).
  이 파일들은 빈 줄이 없는 모양으로 커밋되어 있다(yq가 고쳐 쓸 때 빈 줄을 지우므로). 새 설정을 추가할 때도 이 모양을 지킨다.
  `validate`가 `diff <(yq '.' 파일) 파일`로 이 모양을 검사하므로 어긋난 PR은 머지 전에 걸린다.
- `validate` 잡은 룰셋 "PR 필수"의 필수 상태 검사다(저장소 설정). 룰셋이 잡 이름으로 검사를 찾으므로 이름을 바꾸지 않는다. deploy key는 그 룰셋을 우회하므로 CI의 dev 태그 직접 커밋은
  이 검사를 기다리지 않고, 푸시된 뒤에 `push` 이벤트로 검사가 돈다(결과를 알려 줄 뿐 막지는 못한다. ArgoCD는 GitHub의 검사 결과를 보지 않는다).
- Application을 지우면(루트의 prune 포함) 그것이 배포한 리소스는 클러스터에 남는다(삭제 finalizer를 붙이지 않았다). 네임스페이스와 PostgreSQL의 PVC도 남는다.
- 외부 차트를 쓰는 Application(지금은 `kube-prometheus-stack`)은 값을 `platform/<Application 이름>/values.yaml`에 두고 `$values/`로 가리킨다. 이 값 파일도 환경 값 파일처럼
  빈 줄 없는 yq 모양을 지킨다(`validate`의 플랫폼 차트 단계가 검사한다). 인라인 값(`helm.values`·`valuesObject`·`parameters`)은 그 단계가 렌더링에 넣지 못해 거부한다.
- kube-prometheus-stack의 `crds.enabled`는 끄지 않는다. 렌더링에서 CRD가 빠지면 prune이 CRD를 지우고, CRD가 지워지면 그 종류의 리소스(앱 차트의 ServiceMonitor·SLO 규칙 포함)가 모든 네임스페이스에서 함께 지워진다.

## 막혔을 때

| 증상 | 원인과 조치 |
|---|---|
| Application이 `Unknown`이거나 `ComparisonError` | ArgoCD가 저장소를 읽지 못한다. 저장소가 GitHub에 올라가 있고 공개인지, `targetRevision: main`이 있는지 본다 |
| 앱·PostgreSQL 파드가 `CreateContainerConfigError` | 그 네임스페이스에 `shortener-db` Secret이 없다. 부트스트랩 3번대로 만든다 |
| 동기화가 `Failed`로 멈춘 채 그대로다 | `syncPolicy.retry`를 두지 않아도 자동 동기화는 실패하면 ArgoCD의 기본 재시도를 한다(ArgoCD v3.5.3 소스 기준 최대 5번, 대기는 5초에서 시작해 2배씩 늘고 최대 3분. 진행 중에는 상태 메시지에 `Retrying attempt #N`이 보인다). 이 재시도까지 모두 실패하면 같은 커밋으로는 새 동기화를 시작하지 않는다(selfHeal이 켜져 있어도 같다). 상태 메시지에서 원인을 읽고, 원인을 고친 커밋을 올리거나 UI에서 직접 Sync한다 |
| Application이 오래 `Progressing` | ArgoCD는 Ingress의 `status.loadBalancer.ingress`가 채워져야 Healthy로 본다. `kubectl -n shortener-dev get ingress`의 ADDRESS를 확인한다 |
| 앱이 DB 인증에 실패한다 | Secret을 다시 만들었는데 PostgreSQL 볼륨이 옛 비밀번호로 이미 초기화되어 있다. `POSTGRES_PASSWORD`는 빈 볼륨을 처음 만들 때만 쓰인다. 데이터를 버려도 되면 PVC(`data-shortener-<환경>-postgresql-0`)를 지우고 파드를 다시 띄운다 |
| 커밋했는데 반영이 안 된다 | 폴링을 기다린다(60초 안팎, 길면 2분 가까이). 바로 보려면 위의 `argocd.argoproj.io/refresh` 어노테이션으로 새로고침한다 |
| ArgoCD 파드가 `OOMKilled` | 위 메모리 메모 참고 |
| Grafana 파드가 `CreateContainerConfigError` | `monitoring`에 `grafana-admin` Secret이 없다. 부트스트랩 3-1대로 만든다 |
| Alertmanager 파드가 `ContainerCreating`에 머문다 | `monitoring`에 `alertmanager-discord` Secret이 없어 볼륨을 붙이지 못한다(`kubectl -n monitoring describe pod`의 이벤트에 `FailedMount`). 부트스트랩 3-1대로 만든다 |
| kube-prometheus-stack 동기화가 `metadata.annotations: Too long`으로 실패한다 | Application의 `syncOptions`에서 `ServerSideApply=true`가 빠졌다(위 "모니터링") |
| Discord로 알림이 오지 않는다 | Alertmanager UI(port-forward)에 그 경보가 있는지, 경로(위 "경보가 가는 길")에 맞는지 본다. `kubectl -n monitoring logs alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager`에 notify 오류가 있으면 웹훅 주소 Secret을 확인한다(바꾸는 방법은 `infra/aws/README.md`) |
