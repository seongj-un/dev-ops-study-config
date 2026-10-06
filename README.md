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
argocd/apps/loki.yaml            로그 저장소 Application (외부 차트 + 이 저장소의 값, multi-source)
platform/loki/values.yaml        그 값 (단일 바이너리, 파일시스템 저장, 보존 72h. 아래 "로그")
argocd/apps/alloy.yaml           로그 수집 Application (외부 차트 + 이 저장소의 값, multi-source)
platform/alloy/values.yaml       그 값 (DaemonSet, 로그 수집 파이프라인 설정이 이 안에 있다)
argocd/apps/monitoring-dashboards.yaml      Grafana 대시보드 Application (이 저장소의 kustomize 디렉터리)
platform/dashboards/             대시보드 JSON과 kustomization (ConfigMap으로 만든다. 아래 "대시보드")
argocd/apps/argo-rollouts.yaml      점진 배포 Application (Argo Rollouts: 외부 차트 + 이 저장소의 값, multi-source)
platform/argo-rollouts/values.yaml  그 값 (컨트롤러·CRD·대시보드. 아래 "Argo Rollouts")
tests/slo/                       앱 SLO 규칙(차트의 PrometheusRule)의 promtool 단위 테스트. validate가 차트를 렌더링해 꺼낸 규칙으로 돌린다
tests/canary/                    카나리 분석 쿼리(차트의 AnalysisTemplate)의 promtool 단위 테스트. validate가 렌더링 결과에서 쿼리를 꺼내 돌린다
.github/workflows/validate.yml   PR·main 푸시 검증 (값 파일 형식, helm lint, 렌더링(Rollout·Deployment 두 갈래), 스키마 검사, SLO 규칙·카나리 분석 쿼리 검사, 플랫폼 차트 렌더링, 대시보드 검사)
.github/dependabot.yml           GitHub Actions 주간 갱신
```

| | dev | prod |
|---|---|---|
| 네임스페이스 | `shortener-dev` | `shortener-prod` |
| 주소 | http://dev.dev-ops-study.duckdns.org | http://dev-ops-study.duckdns.org |
| 이미지 태그를 바꾸는 방법 | 앱 저장소 CI가 자동으로 커밋 | 사람이 PR로 승격 |
| 파드 | 2개 고정 | HPA가 2~3개로 조절 (아래 메모리 메모) |
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
  → shortener-dev Application이 자동 동기화 → Rollout 카나리(새 버전을 파드 절반에 올려 1분 기다린 뒤 약 1분 30초 동안 5xx 비율을 재고, 통과하면 전체로. 아래 "카나리 배포 (Argo Rollouts)")
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
- 카나리 분석이 실패한 배포는 Argo Rollouts가 클러스터에서 스스로 옛 버전으로 되돌리지만, Git에는 나쁜 커밋이 그대로 남아 Rollout이 중단된 채로 있다.
  이 절차로 Git도 되돌린다(아래 "카나리 배포 (Argo Rollouts)").
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
- 모니터링(kube-prometheus-stack·Loki·Alloy, 메모리 요청만 약 1.4GiB)은 EC2 클러스터(메모리 8GiB)를 위한 것이다. 로컬 k3d의 Docker VM(2.84GiB)은 앱만으로도 메모리가 모자라
  EC2로 옮겼으므로(아래 메모리 메모) 그 위에는 자리가 없다. 루트 Application은 argocd/apps를 모두 배포하므로 로컬 k3d에서도 모니터링 Application이 생긴다.
  그래도 로컬에서 띄운다면 3-1의 두 Secret을 위처럼 무작위 비밀번호와 가짜 웹훅 주소로 만든다.
- 로컬 k3d에 이전 단계에서 `helm install`로 직접 설치한 `shortener` 릴리스(`shortener` 네임스페이스)가 남아 있으면 먼저 지운다. 로컬용으로 덮어쓴 prod 호스트(`shortener.localhost`)와
  같은 호스트를 쓰는 Ingress가 둘이 되면 요청이 어느 쪽으로 갈지 보장되지 않는다. EC2에는 그런 릴리스가 없다.

확인:

```bash
kubectl -n argocd get applications          # root, shortener-dev·prod, kube-prometheus-stack, loki, alloy, monitoring-dashboards, argo-rollouts가 Synced·Healthy가 될 때까지 몇 분 걸린다
kubectl -n shortener-dev get pods
kubectl -n shortener-prod get pods
kubectl -n monitoring get pods              # 아래 "모니터링"의 파드 8개
kubectl -n argo-rollouts get pods           # 아래 "Argo Rollouts"의 파드 2개
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
| application-controller (StatefulSet) | 50m | 384Mi | 1024Mi |
| repo-server | 25m | 96Mi | 512Mi |
| server | 25m | 64Mi | 192Mi |
| redis | 10m | 16Mi | 64Mi |
| **합계** | **110m** | **560Mi** | **1792Mi** |

- application-controller·repo-server의 메모리 한도는 4단계에서 256Mi에서 512Mi로 올렸다. kube-prometheus-stack은 CRD가 커서(가장 큰 것이 JSON으로 약 486KiB)
  컨트롤러가 캐시에 들고 있는 양이 늘고, repo-server 안에서 도는 `helm pull`·`helm template`이 이 차트에서 최대 RSS를 각각 195MiB·134MiB까지 쓴다(로컬에서 잰 값과 계산은 `bootstrap/argocd/values.yaml`).
  컨트롤러에게는 그 추정이 모자랐다: EC2의 새 인스턴스에서 kube-prometheus-stack을 처음 동기화하는 동안 OOMKilled로 3번 죽었고(다음에 뜬 인스턴스의 기동 중 최고가 509.3MiB로 한도의 99%, 평소는 294~421MiB),
  그래서 컨트롤러를 요청 384Mi(평소 사용량 가까이)·한도 1Gi(잰 최고치의 두 배)로 다시 올렸다. repo-server의 초기화 컨테이너 `copyutil`도 한도 128Mi에서 OOM이 한 번 나서(복사하는 실행 파일이 약 238MiB) 512Mi로 올렸다.
  초기화 컨테이너는 앱 컨테이너보다 먼저 돌고 끝나므로 위 표의 합계에는 넣지 않는다. 근거와 잰 값은 `bootstrap/argocd/values.yaml`의 주석에 있다.
  EC2에서는 부트스트랩이 ArgoCD가 이미 설치돼 있으면 건너뛰므로, 이 값은 인스턴스를 새로 만들 때 적용된다. 떠 있는 클러스터에 바로 넣으려면
  부트스트랩 2번의 `helm upgrade --install`을 다시 돌린다(EC2에서는 위에 적은 대로 `--set server.ingress.enabled=false`도 함께 준다).

끈 컴포넌트:

- **dex**: 없다(파드·리소스 모두). 외부 계정 로그인(SSO)용인데 로컬 admin 로그인만 쓴다.
- **notifications**: 없다(파드·리소스 모두). 동기화 결과를 보낼 곳이 없다.
- **applicationset**: Deployment는 있지만 `replicas: 0`이라 파드가 없다. 이 차트에는 ApplicationSet 컨트롤러를 끄는 스위치가 없고 항상 만들기 때문이다(차트 6.9.0부터, 차트 README의 변경 이력).
  Application을 손으로 적는 이 저장소에서는 쓸 일이 없고, 파드가 없어 메모리를 쓰지 않는다.

- CPU 한도는 두지 않는다(앱 차트와 같은 이유: CFS 쿼터 스로틀링). 위 값은 대부분 클러스터에서 측정한 것이 아니라 작은 규모를 가정한 추정이다(application-controller와 `copyutil`은 EC2에서 잰 값으로 고쳤다). 띄운 뒤 `kubectl top pods -n argocd`로 확인한다.
- 설치·업그레이드 때만 도는 것이 따로 있다: redis 비밀번호 Secret을 만드는 Job(`redis-secret-init`, 끝나면 60초 뒤 지워진다)과 repo-server의 초기화 컨테이너(`copyutil`).
- `server.insecure: true`: TLS를 끝내는 곳이 없어서 서버가 평문 HTTP로만 받는 구성이다(로컬 k3d에서는 브라우저 → Traefik → 서버가 모두 평문 HTTP). 그래서 인터넷에 공개하면 안 되고, EC2에서는 Ingress 없이 port-forward로만 본다.
- ArgoCD 자신은 이 저장소의 Application으로 관리하지 않는다. 설치·업그레이드는 위 `helm upgrade --install` 명령으로 한다.

### `helm.sh/hook: test` 파드는 어떻게 되나

차트의 `templates/tests/test-readiness.yaml`은 `helm.sh/hook: test` 파드다(`helm test`가 readiness 엔드포인트를 확인한다. 앱의 readiness는 readinessState만 본다: DB가 죽어도 파드가 Ready로 남아 캐시된 리다이렉트가 계속 응답하고, 실패는 앱이 기록하는 5xx로 보인다). **ArgoCD는 이 파드를 만들지도 실행하지도 않고 건너뛴다.**

- 근거(문서): ArgoCD 사용자 가이드 Helm 절 — "Argo CD currently skips manifests that include hooks not supported by Argo CD, including Helm test hooks."
- 근거(소스, ArgoCD v3.5.3의 `gitops-engine/pkg/sync`): `helm.sh/hook` 어노테이션이 있으면(`crd-install` 제외) 훅으로 분류되어 일반 리소스 목록에서 빠진다(`hook.IsHook`, `reconcile.go`).
  그런데 동기화 단계로 대응되는 Helm 훅은 `pre-install`·`pre-upgrade`(PreSync)와 `post-install`·`post-upgrade`(PostSync)뿐이고(`hook/helm/type.go`. `pre-delete`·`post-delete`는 삭제 때 도는 훅으로 따로 처리한다),
  훅은 PreSync·Sync·PostSync·SyncFail 단계에서만 실행된다(`sync_phase.go`). `test`는 어느 단계에도 없어서 동기화 작업이 만들어지지 않는다.
  동기화 상태 비교에서도 훅은 제외된다(`controller/state.go`).
- 그래서 이 파드는 클러스터에 생기지 않고 Application의 Sync 상태에도 영향이 없다. 차트에는 남겨 두었다: 다른 클러스터에서 `helm install`로 직접 설치할 때 `helm test`로 쓸 수 있고,
  `helm template` 결과에는 들어가므로 CI의 스키마 검사(kubeconform)는 이 파드도 검사한다.
- ArgoCD로 배포한 앱의 배포 확인은 ArgoCD의 Application 상태(Synced·Healthy)와 위 `curl`로 한다. 앱의 readiness 엔드포인트를 직접 보려면
  `kubectl -n shortener-dev port-forward svc/shortener-dev 8081:8081` 뒤 `curl localhost:8081/actuator/health/readiness`.

## 모니터링 (kube-prometheus-stack, Loki, Alloy)

Application `kube-prometheus-stack`이 Helm 차트 `prometheus-community/kube-prometheus-stack` **91.8.2**를 `platform/kube-prometheus-stack/values.yaml`의 값으로
`monitoring` 네임스페이스에 배포한다. 차트는 외부 차트 저장소에 있고 값만 이 저장소에 있어서 소스를 둘 쓴다(multi-source: 차트 + `ref: values`로 가리키는 이 저장소).
값을 바꾸는 방법은 앱과 같다: 값 파일을 고치는 PR을 머지하면 ArgoCD가 다음 폴링에서 반영한다. Grafana에는 Loki 데이터 소스(`uid: loki`)가 미리 들어 있다.
로그는 Application `loki`(`grafana/loki` **7.3.0**)와 `alloy`(`grafana/alloy` **1.13.0**)가 같은 모양(multi-source)으로, 대시보드는 `monitoring-dashboards`가
이 저장소의 `platform/dashboards`(kustomize)에서 같은 네임스페이스에 배포한다(아래 "로그", "대시보드").

| 파드 | 하는 일 | CPU 요청 | 메모리 요청 / 한도 |
|---|---|---|---|
| `prometheus-kube-prometheus-stack-prometheus-0` (Operator가 만드는 StatefulSet) | 지표 수집·저장, 규칙 평가 | 110m | 528Mi / 1088Mi |
| `alertmanager-kube-prometheus-stack-alertmanager-0` (Operator가 만드는 StatefulSet) | 경보를 묶어 Discord로 보낸다 | 20m | 48Mi / 192Mi |
| `kube-prometheus-stack-operator` | Prometheus·Alertmanager 리소스를 StatefulSet으로, ServiceMonitor·PrometheusRule을 Prometheus 설정으로 바꾼다 | 20m | 64Mi / 192Mi |
| `kube-prometheus-stack-grafana` | 대시보드. 사이드카 2개가 ConfigMap의 대시보드·데이터 소스를 넣는다 | 70m | 320Mi / 768Mi |
| `kube-prometheus-stack-kube-state-metrics` | 쿠버네티스 객체의 상태를 지표로 | 10m | 64Mi / 128Mi |
| `kube-prometheus-stack-prometheus-node-exporter` (DaemonSet) | 노드의 CPU·메모리·디스크 지표 | 10m | 32Mi / 64Mi |
| `loki-0` (StatefulSet) | 로그 저장·검색 (단일 바이너리) | 50m | 256Mi / 512Mi |
| `alloy-<임의>` (DaemonSet) | 노드의 파드 로그를 API로 읽어 Loki로 보낸다. config-reloader 포함 | 30m | 112Mi / 320Mi |
| **합계** | | **320m** | **1424Mi / 3264Mi** |

파드별 값은 config-reloader·사이드카 같은 보조 컨테이너까지 더한 것이다. kube-prometheus-stack의 값은 클러스터에서 잰 값이 아니라 추정이라 띄운 뒤 `kubectl top pods -n monitoring`으로 확인한다.
Loki는 같은 이미지·설정의 로컬 컨테이너에서 잰 값(쓰기만 할 때 working set 115~135MiB, 하루치를 넣고 하루 범위를 물을 때 최고 218MiB)에, Alloy는 로컬에서 잰
기본 사용량(약 46MiB)에 클러스터에서 더해질 몫을 얹은 추정이다(근거는 각 값 파일의 resources 주석).

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
| `service="shortener"` (앱의 SLO 경보와 앱 파드 경보) | Discord |
| `severity="critical"` (그 밖의 critical 경보) | Discord |
| 나머지(warning·info) | 보내지 않는다. Alertmanager UI에서 본다 |

- 같은 `alertname`·`namespace`의 경보를 한 알림으로 묶는다. 첫 알림은 30초 모았다 보내고, 묶음이 바뀌면 5분 간격으로, 그대로 울리면 4시간마다 다시 보낸다. 풀리면(RESOLVED)도 알린다.
- Discord 웹훅 주소는 Git에 없다. 부트스트랩이 SSM 파라미터 `/dev-ops-study/discord-webhook-url`의 값으로 Secret `alertmanager-discord`(키 `webhook-url`)를 만들고,
  Alertmanager가 그 파일(`/etc/alertmanager/secrets/alertmanager-discord/webhook-url`)을 알림을 보낼 때마다 읽는다. 주소를 바꾸는 방법은 `infra/aws/README.md`.
- 클러스터 없이 라우팅을 확인하는 방법은 아래 "로컬에서 검증하기"에 있다.

### SLO 경보가 울리지 않는 장애

앱의 SLO 경보(가용성·지연 번 레이트, `charts/shortener/templates/prometheusrule.yaml`)는 짧거나 일부만 실패하는 장애에는 일부러 울리지 않는다.
그리고 요청이 앱까지 오지 않는 장애는 길어도 보지 못한다. 두 번째 빈자리는 앱 파드 경보가 맡는다.

**짧은 장애·부분 장애는 페이지하지 않는다(예산 계산).** 가용성의 30일 오류 예산은 요청의 0.5%다. 요청이 고르게 온다면 "모든 요청이 실패하는 시간"으로
30일 × 24시간 × 60분 × 0.5% = 216분이다. 빠른 소진 경보는 1시간 비율과 5분 비율이 모두 7.2%(예산의 14.4배)를 넘고 그것이 2분 이어져야 울린다.
1시간 비율은 실패 비율 × 지속 시간 ÷ 60분이므로, 장애가 페이지가 되려면 **실패 비율 × 지속 시간이 4.32분을 넘어야** 한다(14.4배로 1시간 = 30일 예산의 2%).

| 앱이 본 장애 | 1시간 비율의 최고 | 쓴 예산(216분 중) | 페이지 |
|---|---|---|---|
| 100%가 3분 | 5% | 3분(1.4%) | 없다 |
| 100%가 5분 | 8.3% | 5분(2.3%) | 시작 약 6.3분 뒤(4.3분에 기준을 넘고 for 2분) |
| 50%가 5분 | 4.2% | 2.5분(1.2%) | 없다 |
| 20%가 계속 | 20% | 시간에 비례 | 시작 약 23.6분 뒤(21.6분에 기준을 넘고 for 2분) |
| 4%(예산의 8배)가 계속 | 4% | 시간에 비례 | 1시간·5분 짝은 울리지 않는다. 6시간·30분 짝이 약 4.5시간 뒤(`tests/slo`의 (e)) |

몇 분짜리 장애는 30일 예산의 1~2%를 쓴다. 이 설계는 그 정도로는 사람을 부르지 않고, "이 속도가 이어지면 며칠 안에 예산이 바닥난다"일 때만 부른다.
짧은 장애의 흔적은 대시보드의 비율 그래프와 Loki의 로그에 남는다. 지연도 같다: v4 연습의 Redis 차단(약 4분 동안 GET마다 약 1초)에서 5분 창의 느린 요청 비율은
18.5%로 기준 14.4%(지연 예산 1%의 14.4배)를 넘었지만 1시간 비율이 1.0%라 울리지 않았다.

**요청이 앱까지 오지 않으면 SLO에 보이지 않는다.** SLI는 앱 안에서 재는 `http_server_requests` 지표다. 앱 파드가 모두 NotReady가 되면(예전에는 앱의 readiness에 DB가 들어 있어 DB 장애가 곧 이것이었다.
지금은 readinessState만 봐서 DB 장애는 앱이 기록하는 5xx로 SLO에 보이고, 모든 파드의 시작 실패 같은 경우가 남는다) 앱 Service의 엔드포인트가 비고 Traefik이 503을 스스로 돌려준다. 그 요청은 앱의 지표에 남지 않아서 비율의 분모가 0(NaN)이 되고,
장애가 얼마나 길든 SLO 경보는 울리지 않는다. v4 연습(prod, DB 차단)에서 약 5분 동안 요청의 거의 전부가 503이었는데 경보도 Discord 알림도 없었다
(기본 규칙 `KubePodNotReady`가 pending이었을 뿐이다. 그 경보는 warning이고 15분을 기다린다).

**전체 장애는 앱 파드 경보가 맡는다.** `ShortenerNoAvailablePods`(같은 PrometheusRule의 `<릴리스>-pods` 그룹)는 Ready인 앱 파드가 1분 넘게 0개면 울리고,
`service="shortener"`·`severity="critical"`이라 Discord로 간다. 장애가 시작되고 약 2~3분이면 닿는다. 지표는 Argo Rollouts 컨트롤러의 `rollout_info_replicas_available`이고
(앱이 Deployment로 배포된 클러스터에서는 kube-state-metrics의 `kube_deployment_status_replicas_available`), 고른 이유와 한계는 그 파일 머리말의 [앱 파드 경보]에 있다.
노드가 부팅되고 5분 동안은 울리지 않는다(`and on() (time() - max(node_boot_time_seconds) > 300)`). EC2를 켤 때마다 모든 앱 파드가 한꺼번에 다시 떠서
available 0이 1분을 넘기 쉬운데, 그때마다 critical이 Discord로 가면 평소의 시작이 장애처럼 보이기 때문이다.
처음 배포한 뒤 Prometheus에서 `count by (exported_namespace, name) (rollout_info_replicas_available)`가 `shortener-dev`·`shortener-prod`를 하나씩 내는지 본다.
경보는 이 레이블 이름(`exported_namespace`, `name`)으로 Rollout을 고르므로, 이름이 다르면 아무 경고 없이 영영 울리지 않는다.

**아직 덮지 못하는 것.**
- 앱 파드는 Ready인데 그 앞(Traefik, Ingress 설정, 노드의 네트워크)에서 실패하는 요청: 앱 지표에도 파드 수에도 보이지 않는다. 클러스터 밖에서 요청을 보내 보는 검사나
  Traefik의 지표로 재는 SLI가 있어야 잡힌다.
- 노드가 통째로 멈추는 장애: Prometheus와 Alertmanager도 그 노드에 있어서 아무 경보도 나가지 않는다. Watchdog을 보내지 않으므로(위 표) "경보가 끊겼다"를 알려 줄 쪽도 없다.
- 앱 파드 경보는 지표가 없으면 울리지 않는다. Argo Rollouts 컨트롤러가 내려가 있는 동안 앱도 내려가면 조용하다(수집 대상이 내려간 것은 기본 규칙 `TargetDown`이 알리지만 warning이다).
- 위 표의 기준 아래인 부분 장애: 일부러 페이지하지 않는다.
- 노드가 부팅되고 5분 안의 전체 장애: 앱 파드 경보의 부팅 가드가 누른다. 5분이 지나도 앱 파드가 0개면 그때부터 1분 뒤에 울린다.

### 로그 (Loki, Alloy)

```
파드의 stdout·stderr → kubelet → API 서버 → Alloy(DaemonSet, 노드마다 하나) → Loki(loki-0) → Grafana(Explore, 대시보드)
```

- **Alloy**(`platform/alloy/values.yaml`)가 자기 노드의 파드를 찾아 컨테이너 로그를 쿠버네티스 API로 따라 읽는다(`kubectl logs -f`와 같은 길).
  흔한 방식인 "노드의 로그 파일(`/var/log/pods`)을 hostPath로 붙여 읽기"는 쓰지 않는다. 그러면 Alloy가 RBAC와 상관없이 노드에 있는 모든 파드의 로그 파일을 직접 읽고
  (그 파일을 읽으려고 보통 root로 띄운다), API로 읽으면 무엇을 읽을 수 있는지가 RBAC(`pods/log`)로 정해지고 노드의 파일은 하나도 보지 않는다.
  hostNetwork도 쓰지 않는다. 이 클러스터의 불변식은 hostNetwork 파드를 띄우지 않는 것 하나다(IMDS의 홉 제한을 비켜 가므로. `infra/aws/README.md`).
  hostPath·hostPort를 쓰는 파드는 따로 있다: node-exporter(`/proc`·`/sys`·`/`), k3s servicelb의 `svclb-traefik`(hostPort 80·443), local-path의 볼륨 도우미 파드.
- **레이블은 다섯 개뿐이다**: `namespace`, `pod`, `container`, `app`(파드의 `app.kubernetes.io/name`), `level`. 레이블 값의 조합마다 스트림(색인 단위)이 생기므로
  값이 많은 것(요청 ID, URL 등)은 올리지 않는다. `level`은 앱 컨테이너(`app="shortener", container="shortener"`. 같은 차트의 PostgreSQL·Redis 파드도 `app="shortener"`다)의
  줄만 ECS JSON으로 읽어 `log.level`에서 올린다. 실제 줄에서 레벨은 중첩 객체다: `{"@timestamp":…,"log":{"level":"INFO","logger":…},"message":…}`.
  나머지 필드는 줄 안에 남기고 쿼리에서 `| json`으로 꺼낸다.
- **Loki**(`platform/loki/values.yaml`)는 파드 하나(`loki-0`)가 쓰기·읽기·압축을 다 하고, 청크와 색인을 PVC(5Gi, local-path)에 파일로 둔다. 보존은 72시간이다(compactor가 지운다).
  인증 없이 받는다(클러스터 안에서만 닿는다). Ingress를 만들지 않고 Grafana와 Alloy가 `loki.monitoring.svc:3100`으로 닿는다.
- 기본값에서 바꾼 것:
  - Alloy 권한을 `pods`·`pods/log`·`namespaces` 읽기로 줄였다(차트 기본값에는 모든 네임스페이스의 Secret·ConfigMap 읽기가 들어 있다). root 대신 이미지의 alloy 계정(UID 473)으로,
    루트 파일시스템은 읽기 전용으로 띄우고, 어디까지 읽었는지(positions)는 emptyDir에 둔다. 쓰지 않는 PodLogs CRD는 설치하지 않는다.
  - Loki의 캐시(memcached. 차트 기본값대로면 청크 캐시 하나가 메모리 요청 9830Mi)·gateway·canary·규칙 사이드카(켜면 모든 네임스페이스의 Secret을 읽는 ClusterRole이 생긴다)를 껐다.
    Loki 3이 스트림에 붙이는 `service_name` 레이블도 끄고, 둘 다 사용 통계 전송을 껐다.

Grafana(위 port-forward)의 Explore에서 데이터 소스 Loki를 고르고 LogQL로 묻는다:

```
{namespace="shortener-prod", app="shortener", container="shortener"}                         # prod 앱의 모든 줄
{namespace="shortener-prod", app="shortener", container="shortener", level="ERROR"} | json    # ERROR만. JSON 필드를 레이블처럼 꺼낸다(log.logger → log_logger)
{namespace="argocd"} |= "level=error"                                                         # ArgoCD 로그에서 문자열 찾기
```

Alloy UI(파이프라인 그래프, 읽고 있는 컨테이너 목록)는 `kubectl -n monitoring port-forward ds/alloy 12345` 뒤 http://localhost:12345 .
Loki에 직접 물을 때는 `kubectl -n monitoring port-forward svc/loki 3100` 뒤 `curl localhost:3100/ready`, `curl -G localhost:3100/loki/api/v1/labels`.

### 대시보드

Grafana의 **Shortener** 대시보드(http://localhost:3000/d/shortener)는 `platform/dashboards/shortener.json`에서 온다. 맨 위 "환경"에서 dev·prod(네임스페이스)를 고른다.

| 줄 | 패널 |
|---|---|
| SLO | 가용성 1시간·6시간·1일, 오류 예산 소진 속도(가용성·지연. 5분·30분·1시간·6시간 창, 경보 기준 6·14.4는 점선) |
| 트래픽 | 초당 요청 수(상태 코드 계열별), 5xx 비율(5분·1시간 창), 응답 시간 p50·p95·p99(SLO 기준 0.3초는 점선) |
| 앱 지표 | 단축 URL 생성·리다이렉트(초당), 캐시 적중률(Redis 오류 비율도 함께) |
| 로그 | 앱 로그 줄 수(레벨별, Loki), ERROR 로그(Loki) |

- SLO 패널은 앱 차트의 SLO 기록 규칙(`namespace_job:http_server_requests_errors:ratio_rate<창>`, `namespace_job:http_server_requests_slow:ratio_rate<창>`)을 그대로 읽는다. 경보가 보는 값과 같다.
- 30일 오류 예산의 남은 양은 보여 주지 않는다. Prometheus는 3일만 보존하고 클러스터는 공부할 때만 띄우므로 소진 속도(번 레이트)와 1시간·6시간·1일 가용성으로 본다.
  1일 창은 기록 규칙이 없어서 원래 지표(`http_server_requests_seconds_count`)로 같은 식을 계산한다.
- 대시보드를 고치려면 Grafana에서 고친 뒤(Git에서 온 대시보드라 저장은 되지 않는다) Export → Export as JSON으로 받아 `platform/dashboards/`의 파일을 바꾸고 PR로 머지한다.
  새 대시보드는 JSON 파일을 두고 `platform/dashboards/kustomization.yaml`의 `files`에 한 줄을 더한다. 데이터 소스는 uid(`prometheus`, `loki`)로 가리키고, 대시보드에는 uid를 꼭 둔다.

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

## Argo Rollouts (컨트롤러·대시보드)

Application `argo-rollouts`가 Helm 차트 `argo/argo-rollouts` **2.43.2**(Argo Rollouts v1.10.0)를 `platform/argo-rollouts/values.yaml`의 값으로 `argo-rollouts` 네임스페이스에 배포한다.
모니터링과 같은 multi-source 모양이라(차트 + `ref: values`로 가리키는 이 저장소) 값을 바꾸는 방법도 같다. 이 Application은 컨트롤러와 CRD 5개(`Rollout`, `AnalysisRun`, `AnalysisTemplate`,
`ClusterAnalysisTemplate`, `Experiment`), 대시보드만 설치한다. `Rollout`을 쓰는 쪽은 앱 차트(`charts/shortener`)이고 이 Application과 따로 배포된다.

| 파드 | 하는 일 | CPU 요청 | 메모리 요청 / 한도 |
|---|---|---|---|
| `argo-rollouts` | 컨트롤러: Rollout을 보고 새 버전의 ReplicaSet을 단계적으로 늘리고, 분석(AnalysisRun)을 돌린다 | 20m | 64Mi / 192Mi |
| `argo-rollouts-dashboard` | 웹 UI (Rollout·Deployment 쓰기 권한 없음) | 10m | 32Mi / 128Mi |
| **합계** | | **30m** | **96Mi / 320Mi** |

값은 클러스터에서 잰 값이 아니라 이 규모(Rollout 2개)를 가정한 추정이라 띄운 뒤 `kubectl top pods -n argo-rollouts`로 확인한다(근거는 값 파일의 resources 주석. 대시보드는 쿠버네티스 API 없이 띄운 로컬 컨테이너에서
유휴 약 15MiB를 쟀고, 컨트롤러는 API 없이는 뜨지 않아 재지 못했다). 합계는 아래 메모리 메모에 들어 있다.

### 대시보드 열기 (port-forward)

Ingress를 만들지 않는다. 대시보드에는 인증이 없고 80 포트는 인터넷에 열린 평문 HTTP라서(위 "열어 보기"와 같은 이유) 맥에서 port-forward로만 본다.

```bash
kubectl -n argo-rollouts port-forward svc/argo-rollouts-dashboard 3100:3100     # http://localhost:3100/rollouts
```

화면 위쪽의 네임스페이스 선택에서 `shortener-dev`·`shortener-prod`를 고른다(Rollout이 있는 네임스페이스가 목록에 나온다). 대시보드의 ClusterRole에서는 Rollout·Deployment 쓰기 권한을 뺐다(`dashboard.readonly: true`).
인증이 없는 UI가 쓰기 권한을 가지면 클러스터 안의 어느 파드든 그 Service로 Rollout의 승격·중단·재시도·되돌리기·이미지 교체를 시킬 수 있어서(이 저장소는 NetworkPolicy를 두지 않는다) 뺐다.
읽기 권한은 그대로이고, 차트는 `leases`의 create·get·update를 `readonly`와 상관없이 남긴다. 그래서 화면의 승격·중단 버튼을 누르면 쿠버네티스 API가 forbidden으로 거부해 오류가 난다.
조작은 Git으로 하거나 kubectl 플러그인(`kubectl argo rollouts promote`, `kubectl argo rollouts abort`)으로 한다.

### 기본값에서 바꾼 것

- **컨트롤러 파드 1개**(차트 기본값은 2개이고 리더 선출로 하나만 일한다). 노드가 하나라 둘째 파드는 노드 장애를 막지 못하고 메모리만 쓴다. 컨트롤러가 잠시 없어도 이미 뜬 앱 파드는 그대로 서비스되고 진행 중인 카나리 단계만 멈춘다.
  다만 HPA가 Rollout을 가리키는 환경(prod)에서는 그동안 HPA가 바꾼 파드 수도 파드에 반영되지 않는다(Rollout의 ReplicaSet 수는 이 컨트롤러가 맞춘다).
- **대시보드를 켰다**(차트 기본값은 꺼짐). ClusterIP이고 Ingress·HTTPRoute는 없으며 Rollout·Deployment 쓰기 권한이 없다(위).
- **지표**: 컨트롤러의 지표 Service(`argo-rollouts-metrics`, 8090)와 ServiceMonitor를 켰다(차트 기본값은 둘 다 꺼짐). Prometheus는 레이블 없이 모든 네임스페이스의 ServiceMonitor를 고르므로 따로 설정할 것이 없다.
  위 "열어 보기"의 Prometheus port-forward 뒤 `up{job="argo-rollouts-metrics"}`가 1이고 `argo_rollouts_controller_info`가 나오는지 본다. Rollout이 생기면 `rollout_info`도 나온다.
  앱 차트의 앱 파드 경보가 이 지표(`rollout_info_replicas_available`)를 읽는다(위 "SLO 경보가 울리지 않는 장애"). 이 차트의 ServiceMonitor에는 `honorLabels`가 없어서
  (Prometheus Operator의 기본값 false) 지표의 `namespace`(Rollout의 네임스페이스)는 `exported_namespace`로 바뀌어 저장되고 `namespace`에는 `argo-rollouts`가 붙는다.
  경보가 그 이름으로 Rollout을 고르므로, 값 파일의 `relabelings`·`metricRelabelings`로 레이블을 바꾸면 `charts/shortener/templates/prometheusrule.yaml`의 식도 함께 바꾼다.
- **알림은 쓰지 않는다.** 차트에는 알림을 끄는 스위치가 없어서, 설정을 담는 ConfigMap과 토큰을 담는 Secret을 둘 다 만들지 않았다. 컨트롤러는 둘이 없으면 빈 설정으로 읽고 아무것도 보내지 않는다.
- **트래픽 라우터 권한을 뺐다**(`providerRBAC.enabled: false`와 `providers.gatewayAPI: false`). 컨트롤러의 ClusterRole에서 Istio·SMI·Ambassador·AWS ALB·App Mesh·Traefik·Apisix·Contour·Gloo·Gateway API용 규칙이 빠져
  렌더링한 ClusterRole이 약 290줄에서 약 165줄로 준다. 이 저장소는 트래픽 라우터 없이 파드 수의 비율로 나누는 기본 카나리만 쓰므로 쓸 곳이 없는 규칙이다(트래픽 라우터를 쓰게 되면 다시 켠다).
  `gatewayAPI`는 `enabled`와 따로 `configmaps`의 create·update를 붙이므로 함께 껐다(업스트림 기본 ClusterRole의 `configmaps`도 get·list·watch뿐이다).
  남는 권한 중 이 차트의 값으로 줄일 수 없는 것: 모든 네임스페이스의 Secret 읽기(분석 템플릿이 Secret을 참조할 수 있다), Job·Service·Ingress 쓰기(분석 Job, 카나리·안정 Service의 selector, Ingress 어노테이션).
- **CRD는 차트가 설치하고 지우지 못하게 지킨다.** CRD가 지워지면 그 종류의 리소스가 모든 네임스페이스에서 함께 지워지고, Rollout이 지워지면 그 ReplicaSet과 파드도 지워져 앱이 내려간다.
  ArgoCD는 삭제 finalizer를 붙여 Application을 지워도 CRD를 지우지 않지만(차트 기본값 `keepCRDs`가 붙이는 `helm.sh/resource-policy: keep`도 같은 뜻으로 읽는다), prune은 그 어노테이션을 보지 않는다.
  그래서 값 파일의 `crdAnnotations`로 모든 CRD에 `argocd.argoproj.io/sync-options: Prune=false`를 붙였다. 차트의 CRD는 설명(description) 필드를 뺀 것이라 `kubectl explain rollout.spec`은 필드 이름만 보여 준다.
- **ServerSideApply=true**: 이 차트의 CRD는 가장 큰 `rollouts`가 JSON으로 약 67KiB라 클라이언트 쪽 적용의 어노테이션 한도(256KiB)에 아직 닿지 않는다(kube-prometheus-stack의 CRD와 다르다).
  업스트림의 CRD(설명 포함)는 `rollouts`가 약 283KiB로 한도를 넘고 Argo Rollouts 설치 문서도 CRD를 따로 넣을 때는 서버 쪽 적용을 쓰라고 해서, 차트가 설명을 되살리거나 CRD가 커져도 막히지 않게 켰다.
- **첫 동기화의 순서**: ServiceMonitor의 CRD는 kube-prometheus-stack이 설치하는데 이 차트는 CRD가 있는지 보지 않고 ServiceMonitor를 만든다. 새 클러스터에서 이 Application이 먼저 동기화되면 ArgoCD는 그 종류를 찾지 못해 동기화를 통째로 거부한다.
  그래서 ServiceMonitor에만 `SkipDryRunOnMissingResource=true` 어노테이션을 붙여(값 파일의 `additionalAnnotations`. Application 전체에 걸면 CRD가 없는 다른 종류까지 검증을 건너뛴다) 그 리소스의 검증만 건너뛰고,
  나머지(CRD, 컨트롤러, 대시보드)를 먼저 적용한다. ServiceMonitor는 `retry`(6번, 합쳐 약 8분)로 CRD가 생길 때까지 다시 시도한다. ArgoCD의 기본 재시도는 합쳐 약 2분 반이다.
  대가는 다시 시도를 기다리는 동안 동기화 작업이 `Running`으로 남아 자동 동기화가 새 커밋을 적용하지 않는 것이다(아래 "막혔을 때").
- ArgoCD 컨트롤러의 메모리에 주는 영향은 작다. 이 차트가 더하는 매니페스트는 객체 20개, JSON으로 약 0.3MiB(그중 CRD 5개가 약 0.28MiB)로 kube-prometheus-stack(약 3.0MiB)의 10분의 1이다.
  그래도 새 인스턴스에서 처음 동기화할 때 컨트롤러의 최고 사용량(`memory.peak`)을 다시 본다(근거는 `bootstrap/argocd/values.yaml`의 컨트롤러 주석).

## 메모리 메모

노드는 EC2 `m7i-flex.large`(2 vCPU, 메모리 8GiB = 8192Mi) 한 대다. 로컬 Docker VM(2.84GiB)은 dev 롤링 업데이트 중에 메모리가 모자라서 프로젝트를 이 노드로 옮겼다.
8GiB에서는 앱 메모리를 줄일 이유가 없어 두 환경 모두 차트 기본값(요청 384Mi·한도 512Mi)으로 되돌렸고, prod의 HPA를 다시 켰다(파드 2~3개). dev는 파드 2개 고정이다
(5단계에서 카나리 때문에 dev를 1개에서 2개로, prod의 최소를 1개에서 2개로 올렸다. 아래 "카나리 배포").
JVM 최대 힙은 컨테이너 메모리 한도의 75%(앱 이미지의 `-XX:MaxRAMPercentage=75.0`)라서 한도 512Mi에서는 384Mi다.

| | 요청 합 | 한도 합 |
|---|---|---|
| k3s와 기본 구성요소 (Traefik 등. 사용량으로 잡은 값) | 약 800Mi | 약 800Mi |
| ArgoCD (파드 4개. 4단계에서 repo-server 한도를 512Mi로, 컨트롤러 요청·한도를 384Mi·1024Mi로 올렸다) | 560Mi | 1792Mi |
| 모니터링: kube-prometheus-stack (파드 6개, 위 "모니터링" 표) | 1056Mi | 2432Mi |
| 모니터링: Loki·Alloy (파드 2개, 위 "모니터링" 표) | 368Mi | 832Mi |
| 점진 배포: Argo Rollouts (파드 2개, 위 "Argo Rollouts" 표. 5단계) | 96Mi | 320Mi |
| dev (앱 384Mi/512Mi + PostgreSQL 128Mi/256Mi + Redis 32Mi/128Mi, 앱 2개) | 928Mi | 1408Mi |
| prod, HPA가 최대 3개까지 늘었을 때 (앱 3개 + PostgreSQL 256Mi/512Mi로 키움 + Redis 32Mi/128Mi) | 1440Mi | 2176Mi |
| 합계 | 5248Mi | 9760Mi |
| 배포(카나리, Argo Rollouts가 없으면 롤링 업데이트) 중 환경마다 앱 파드 하나 추가 (maxSurge 1) | +384Mi | +512Mi |
| 합계, 두 환경이 동시에 배포 중일 때 | 6016Mi | 10784Mi |

- **요청 합은 최악에도 노드 안에 든다.** 요청은 스케줄러가 자리를 계산하는 값이다. prod가 3개인 채 두 환경이 동시에 배포해도(차트의 파드 템플릿을 고치면 두 환경이 같은 `main`의 차트를 읽어 동시에 배포된다)
  6016Mi로 8192Mi(실제 MemTotal은 약 7.6GiB)보다 작다. 카나리는 늘어난 파드 하나를 대기와 분석(약 2분 30초) 동안 띄워 두므로(prod가 3개면 카나리 2개·stable 2개) 이 최악이 롤링 업데이트보다 오래간다.
  4단계에서 새로 더하는 요청은 약 1.6GiB까지로 잡았고(ArgoCD 컨트롤러 요청을 128Mi에서 384Mi로 올린 256Mi는 위 ArgoCD 행에 따로 들어 있다),
  그중 kube-prometheus-stack이 1056Mi, Loki·Alloy가 368Mi를 쓴다(합 1424Mi. Loki·Alloy 몫으로 남겨 둔 약 580Mi 가운데 약 210Mi가 남는다). 5단계의 Argo Rollouts 96Mi는 그 몫과 별개로 위 합계에 더했다.
  같은 계산이 `environments/prod/values.yaml`의 `autoscaling` 위 주석에도 있다(prod의 HPA 최대 3개를 정한 근거).
- **한도 합은 최악에 노드 메모리를 넘는다(오버커밋).** 3단계까지는 모든 컨테이너가 한도까지 쓰는 최악(5664Mi)도 노드 안에 들게 잡았지만, 모니터링과 ArgoCD 한도를 더하니 넘고, 5단계에서 Argo Rollouts의 한도 320Mi와 dev 앱 하나를 더해 10784Mi가 된다.
  모든 컨테이너가 한꺼번에 한도까지 쓰는 일은 드물다고 보고 받아들인다. 한도는 컨테이너 하나가 폭주할 때 그 컨테이너만 OOMKilled로 멈추게 하는 상한이다.
  한도보다 노드가 먼저 모자라면 kubelet이 요청을 넘게 쓰는 파드부터 내쫓는다(그래서 요청을 평소 사용량 가까이 잡는다). 띄운 뒤 실제 사용량으로 다시 본다.
- 위 합계는 추정이다. k3s 행의 약 800Mi는 로컬 k3d의 빈 클러스터에서 잰 약 770MiB를 올려 잡은 값이고 EC2에서는 재지 않았다. 8GiB는 명목 크기라 실제 MemTotal은 조금 작고 호스트 OS도 메모리를 쓰므로 그만큼 위 여유가 줄어든다.
  한도는 상한일 뿐 평소 사용량은 훨씬 작다: 2단계에서 한도 512Mi로 띄웠을 때 유휴 상태의 앱 파드는 약 320Mi, PostgreSQL은 약 55Mi, Redis는 약 15Mi였다(`kubectl top`). 띄운 뒤 실제 값을 확인한다: `kubectl top pods -A --sort-by=memory`, 노드에서 `free -m`.
- **prod가 최대 3개까지 늘 수 있다고 보고 예산을 잡았다.** 2단계에서는 새 파드가 뜬 직후 HPA가 앱을 1개에서 2개로 늘렸다가 5분쯤 뒤에 줄이는 일이 여러 번 있었다(콜드 JVM의 CPU 급증 때문으로 추정하지만 그 순간의 CPU는 재지 않았다).
  HPA 자체는 2단계에서 이미 연습했다. 차트의 기본값(HPA 1~2개)은 그대로 두었고 prod의 환경 값 파일이 최대를 3개로 덮어쓴다.
  메모리 말고 DB 커넥션도 파드 수를 받쳐 줘야 한다: 앱 파드가 커넥션을 10개씩 잡아 최대 4개(3개 + 배포 중 1개)면 40개인데 차트 PostgreSQL의 `max_connections`는 30이다.
  그래서 prod의 PostgreSQL은 `max_connections`를 60으로, 메모리를 요청 256Mi·한도 512Mi로 키웠다. dev도 5단계에서 파드 2개 + 배포 중 1개 = 30개가 되어 `max_connections`만 50으로 올렸다
  (계산은 각 환경 값 파일의 `postgresql` 위 주석).
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
PROMETHEUS_IMAGE=$(yq '.jobs.validate.env.PROMETHEUS_IMAGE' .github/workflows/validate.yml)
out=$(mktemp -d)

mkdir -p tests/slo/rendered     # 렌더링해서 꺼낸 SLO 규칙을 둘 곳(.gitignore에 있다)
for env in dev prod; do
  diff <(yq '.' environments/$env/values.yaml) environments/$env/values.yaml     # 값 파일이 yq가 쓰는 모양인가 (출력이 없어야 한다)
  helm lint charts/shortener --strict --kube-version $KUBERNETES_VERSION -f environments/$env/values.yaml
  # --api-versions: 모니터링 CRD와 Argo Rollouts가 있는 클러스터(지금의 EC2)처럼 렌더링해서 ServiceMonitor·PrometheusRule·Rollout·AnalysisTemplate도 나오게 한다
  # (ArgoCD는 클러스터의 API 목록을 넘긴다)
  helm template shortener-$env charts/shortener --namespace shortener-$env --kube-version $KUBERNETES_VERSION \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor --api-versions monitoring.coreos.com/v1/PrometheusRule \
    --api-versions argoproj.io/v1alpha1 --api-versions argoproj.io/v1alpha1/Rollout --api-versions argoproj.io/v1alpha1/AnalysisTemplate \
    -f environments/$env/values.yaml > $out/shortener-$env.yaml
  docker run -i --rm $KUBECONFORM_IMAGE -strict -summary -schema-location "$K8S_SCHEMA_LOCATION" -schema-location "$CRD_SCHEMA_LOCATION" \
    -kubernetes-version $KUBERNETES_VERSION - < $out/shortener-$env.yaml
  yq 'select(.kind == "PrometheusRule") | .spec' $out/shortener-$env.yaml > tests/slo/rendered/shortener-$env.yaml
  # 앱 파드 경보는 Argo Rollouts가 없는 클러스터(앱이 Deployment)에서 다른 지표를 읽으므로 그 갈래의 규칙도 꺼낸다
  helm template shortener-$env charts/shortener --namespace shortener-$env --kube-version $KUBERNETES_VERSION \
    --api-versions monitoring.coreos.com/v1/PrometheusRule -f environments/$env/values.yaml \
    | yq 'select(.kind == "PrometheusRule") | .spec' > tests/slo/rendered/shortener-$env-deployment.yaml
done

# SLO 규칙과 앱 파드 경보: promtool로 문법을 검사하고 단위 테스트(tests/slo/의 두 테스트 파일)를 돌린다
docker run --rm -v "$PWD/tests/slo:/slo:ro" --entrypoint /bin/promtool "$PROMETHEUS_IMAGE" \
  check rules --lint-fatal /slo/rendered/shortener-dev.yaml /slo/rendered/shortener-prod.yaml \
  /slo/rendered/shortener-dev-deployment.yaml /slo/rendered/shortener-prod-deployment.yaml
docker run --rm -v "$PWD/tests/slo:/slo:ro" --entrypoint /bin/promtool "$PROMETHEUS_IMAGE" \
  test rules /slo/shortener-slo.test.yaml /slo/shortener-slo-deployment.test.yaml

docker run --rm -v "$PWD":/work:ro -w /work $KUBECONFORM_IMAGE -strict -summary \
  -schema-location "$K8S_SCHEMA_LOCATION" -schema-location "$CRD_SCHEMA_LOCATION" -kubernetes-version $KUBERNETES_VERSION argocd/
```

`helm template`은 ArgoCD가 하는 것과 같이 릴리스 이름(`shortener-dev`)과 네임스페이스를 주고 환경 값 파일을 얹어 렌더링한다. `image.tag`가 커밋 SHA 40자가 아니거나 DB Secret 이름이 없으면
차트가 안내 메시지와 함께 실패한다. `helm lint`에는 `--api-versions` 옵션이 없어서 ServiceMonitor·PrometheusRule은 lint에서 렌더링되지 않는다(내용은 렌더링·kubeconform·promtool이 검사한다).
SLO 규칙 테스트의 시나리오와 읽는 법은 `tests/slo/shortener-slo.test.yaml`의 머리말에 있다. 워크플로 파일은 `docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.12`로 검사한다.

플랫폼 차트(argocd/apps에서 `chart:` 소스를 쓰는 Application. 지금은 kube-prometheus-stack, loki, alloy, argo-rollouts)는 CI 단계의 스크립트를 그대로 꺼내 돌린다.
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

Loki와 Alloy의 설정 파일은 값 파일에 그대로 있지 않다(Loki는 차트가 값으로 설정 파일을 만들고, Alloy 설정은 값 안의 문자열이 tpl을 거친다). 렌더링한 ConfigMap에서 꺼내
같은 버전의 프로그램으로 검사한다(이미지 태그는 차트가 쓰는 버전과 같게 둔다). `loki -verify-config`는 설정을 읽어 검사만 하고 끝난다.
`alloy validate`는 문법, 컴포넌트·인자 이름, 컴포넌트 사이의 참조를 본다. 함수 이름(`sys.env` 등)은 Alloy가 실행하면서 계산하므로 validate가 잡지 못한다.

```bash
w=$(mktemp -d)
helm template loki loki --repo https://grafana.github.io/helm-charts --version 7.3.0 -n monitoring -f platform/loki/values.yaml \
  | yq 'select(.kind == "ConfigMap" and .metadata.name == "loki") | .data."config.yaml"' > $w/config.yaml
docker run --rm -v $w:/w:ro grafana/loki:3.6.11 -config.file=/w/config.yaml -verify-config
helm template alloy alloy --repo https://grafana.github.io/helm-charts --version 1.13.0 -n monitoring -f platform/alloy/values.yaml \
  | yq 'select(.kind == "ConfigMap") | .data."config.alloy"' > $w/config.alloy
docker run --rm -v $w:/w:ro grafana/alloy:v1.20.0 validate /w/config.alloy
```

대시보드는 CI 단계처럼 JSON을 검사하고 kustomize로 렌더링해 스키마로 검사한다. kustomize는 CI·ArgoCD와 같은 5.8.1을 쓴다
(kubectl 1.36에 들어 있는 kustomize도 5.8.1이라 `kustomize build` 대신 `kubectl kustomize platform/dashboards`로 해도 된다):

```bash
for f in platform/dashboards/*.json; do jq -e 'type == "object" and (.uid | type == "string") and (.title | type == "string")' $f > /dev/null && echo "$f ok"; done
kustomize build platform/dashboards | docker run -i --rm $KUBECONFORM_IMAGE -strict -summary -schema-location "$K8S_SCHEMA_LOCATION" \
  -kubernetes-version $KUBERNETES_VERSION -
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
| Loki 차트 | `grafana/loki` 7.3.0 (Loki 3.6.11. 이 차트는 이제 GEL용이고 OSS용은 grafana-community로 옮겨 갔다: 값 파일 맨 위 주석) | `argocd/apps/loki.yaml`의 `targetRevision`, 값 파일 맨 위 주석, 이 README |
| Alloy 차트 | `grafana/alloy` 1.13.0 (Alloy v1.20.0, config-reloader v0.94.0) | `argocd/apps/alloy.yaml`의 `targetRevision`, 값 파일 맨 위 주석, 이 README |
| Argo Rollouts 차트 | `argo/argo-rollouts` 2.43.2 (Argo Rollouts v1.10.0. 이미지 태그도 이 차트 버전이 정한다) | `argocd/apps/argo-rollouts.yaml`의 `targetRevision`, 값 파일 맨 위 주석, 이 README |
| kustomize (CI) | v5.8.1 (릴리스 파일을 받아 SHA-256으로 확인한다. ArgoCD v3.5.3에 들어 있는 kustomize와 같다) | `validate.yml` 대시보드 단계의 `KUSTOMIZE_VERSION`·`KUSTOMIZE_SHA256` |
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
- 외부 차트를 쓰는 Application(지금은 `kube-prometheus-stack`, `loki`, `alloy`, `argo-rollouts`)은 값을 `platform/<Application 이름>/values.yaml`에 두고 `$values/`로 가리킨다. 이 값 파일도 환경 값 파일처럼
  빈 줄 없는 yq 모양을 지킨다(`validate`의 플랫폼 차트 단계가 검사한다). 인라인 값(`helm.values`·`valuesObject`·`parameters`)은 그 단계가 렌더링에 넣지 못해 거부한다.
- kube-prometheus-stack의 `crds.enabled`는 끄지 않는다. 렌더링에서 CRD가 빠지면 prune이 CRD를 지우고, CRD가 지워지면 그 종류의 리소스(앱 차트의 ServiceMonitor·SLO 규칙 포함)가 모든 네임스페이스에서 함께 지워진다.
- Argo Rollouts의 `installCRDs`도 끄지 않는다. 값 파일의 `crdAnnotations`(`Prune=false`)가 prune에서는 CRD를 지켜 주지만, CRD가 지워지면 Rollout이 모든 네임스페이스에서 지워지고 그 ReplicaSet과 파드까지 따라 지워져 앱이 내려간다.
  Argo Rollouts를 정말 없앨 때는 먼저 모든 Rollout을 Deployment로 되돌린 뒤 `kubectl delete crd`로 손으로 지운다.
- Alloy 설정(`platform/alloy/values.yaml`의 `alloy.configMap.content`)은 차트가 Helm의 tpl로 한 번 더 렌더링한다. 여는 중괄호 두 개를 연달아 쓰면 Helm 템플릿으로 읽히므로 쓰지 않는다.
  파이프라인을 고친 뒤에는 위 "로컬에서 검증하기"의 `alloy validate`로 확인한다.
- Loki 레이블은 다섯 개(`namespace`, `pod`, `container`, `app`, `level`)로 둔다. 값이 많은 필드(요청 ID, URL 등)는 레이블로 올리지 않고 쿼리에서 `| json`으로 꺼낸다.

## 막혔을 때

| 증상 | 원인과 조치 |
|---|---|
| Application이 `Unknown`이거나 `ComparisonError` | ArgoCD가 저장소를 읽지 못한다. 저장소가 GitHub에 올라가 있고 공개인지, `targetRevision: main`이 있는지 본다 |
| 앱·PostgreSQL 파드가 `CreateContainerConfigError` | 그 네임스페이스에 `shortener-db` Secret이 없다. 부트스트랩 3번대로 만든다 |
| 동기화가 `Failed`로 멈춘 채 그대로다 | `syncPolicy.retry`를 두지 않아도 자동 동기화는 실패하면 ArgoCD의 기본 재시도를 한다(ArgoCD v3.5.3 소스 기준 최대 5번, 대기는 5초에서 시작해 2배씩 늘고 최대 3분. 진행 중에는 상태 메시지에 `Retrying attempt #N`이 보인다). 이 재시도까지 모두 실패하면 같은 커밋으로는 새 동기화를 시작하지 않는다(selfHeal이 켜져 있어도 같다). 상태 메시지에서 원인을 읽고, 원인을 고친 커밋을 올리거나 UI에서 직접 Sync한다 |
| 고친 커밋을 올렸는데 반영되지 않고 동기화 작업이 `Running`이며 상태 메시지에 `Retrying attempt #N`이 보인다 | 다시 시도를 기다리는 동안 동기화 작업이 `Running`으로 남아 있고, 자동 동기화는 그동안 새 커밋으로 새 동기화를 시작하지 않는다(다시 시도도 처음 커밋을 쓴다). 고친 커밋을 바로 적용하려면 UI에서 그 작업을 Terminate한 뒤 Sync한다. 기다리는 시간은 argo-rollouts가 최대 약 8분(6번), 다른 Application은 ArgoCD 기본값으로 약 2분 반(5번)이다 |
| Application이 오래 `Progressing` | ArgoCD는 Ingress의 `status.loadBalancer.ingress`가 채워져야 Healthy로 본다. `kubectl -n shortener-dev get ingress`의 ADDRESS를 확인한다 |
| 앱이 DB 인증에 실패한다 | Secret을 다시 만들었는데 PostgreSQL 볼륨이 옛 비밀번호로 이미 초기화되어 있다. `POSTGRES_PASSWORD`는 빈 볼륨을 처음 만들 때만 쓰인다. 데이터를 버려도 되면 PVC(`data-shortener-<환경>-postgresql-0`)를 지우고 파드를 다시 띄운다 |
| 커밋했는데 반영이 안 된다 | 폴링을 기다린다(60초 안팎, 길면 2분 가까이). 바로 보려면 위의 `argocd.argoproj.io/refresh` 어노테이션으로 새로고침한다 |
| ArgoCD 파드가 `OOMKilled` | 위 메모리 메모 참고 |
| Grafana 파드가 `CreateContainerConfigError` | `monitoring`에 `grafana-admin` Secret이 없다. 부트스트랩 3-1대로 만든다 |
| Alertmanager 파드가 `ContainerCreating`에 머문다 | `monitoring`에 `alertmanager-discord` Secret이 없어 볼륨을 붙이지 못한다(`kubectl -n monitoring describe pod`의 이벤트에 `FailedMount`). 부트스트랩 3-1대로 만든다 |
| kube-prometheus-stack 동기화가 `metadata.annotations: Too long`으로 실패한다 | Application의 `syncOptions`에서 `ServerSideApply=true`가 빠졌다(위 "모니터링") |
| argo-rollouts 동기화가 `Failed`로 보이고 메시지에 `ServiceMonitor`가 나온다 | 새 클러스터에서 kube-prometheus-stack보다 먼저 동기화돼, 그 차트가 설치하는 ServiceMonitor CRD(`kubectl get crd servicemonitors.monitoring.coreos.com`)가 아직 없다. CRD·컨트롤러·대시보드는 이미 적용돼 있고 ServiceMonitor만 다시 시도 중이라(6번, 약 8분) kube-prometheus-stack이 그 CRD를 만들고 나면 저절로 풀린다. 다시 시도를 모두 쓰고도 `Failed`로 멈춰 있으면 UI에서 직접 Sync한다(위 "Argo Rollouts") |
| Grafana의 로그 패널이 비어 있거나 Loki 데이터 소스가 오류 | `kubectl -n monitoring get pods`로 `loki-0`이 Ready인지(뜬 뒤 준비까지 1분 안쪽), `alloy-*` 파드가 Running인지 본다. Alloy UI(위 "로그")에서 컴포넌트가 healthy인지와 읽고 있는 대상을, `kubectl -n monitoring logs ds/alloy -c alloy`에서 `loki.write`의 전송 오류를 본다. 단, Alloy 파드가 새로 뜬 직후 나오는 `final error sending batch, no retries left, dropping data` ... `status=400` ... `entry too far behind`는 문제가 아니다: 각 컨테이너의 로그 파일을 처음부터 다시 보내다가 그 스트림의 가장 새 줄보다 1시간 넘게 오래된 줄(이미 저장된 줄)을 Loki가 거절한 것이고, 같은 묶음의 다른 줄은 저장된다(`platform/alloy/values.yaml`의 mounts 주석) |
| Alloy 로그에 `forbidden` | Alloy의 ClusterRole(`platform/alloy/values.yaml`의 `rbac`)에 그 컴포넌트가 쓰는 권한이 없다. 컴포넌트를 더했다면 필요한 권한도 더한다(차트 values.yaml의 rbac 주석에 컴포넌트별 권한이 있다) |
| Discord로 알림이 오지 않는다 | Alertmanager UI(port-forward)에 그 경보가 있는지, 경로(위 "경보가 가는 길")에 맞는지 본다. `kubectl -n monitoring logs alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager`에 notify 오류가 있으면 웹훅 주소 Secret을 확인한다(바꾸는 방법은 `infra/aws/README.md`) |

## 카나리 배포 (Argo Rollouts)

앱은 Deployment가 아니라 Argo Rollouts의 **Rollout**으로 배포된다(두 환경 모두 `rollout.enabled: true`. Argo Rollouts 자체의 설치는 위 "Argo Rollouts (컨트롤러·대시보드)").
파드 템플릿이 바뀌는 변경(이미지 태그, ConfigMap 값의 체크섬, 리소스, `fault.errorRate` 등)은 한 번에 퍼지지 않고 파드의 절반에 먼저 올라간다(카나리).
1분 기다린 뒤 그 파드들의 5xx 비율을 30초 간격으로 4번 재고, 통과해야 모든 파드로 넓힌다. 5% 이상인 측정이 두 번이면(또는 카나리 파드가 5분 안에 Ready가 되지 못하면)
Argo Rollouts가 스스로 배포를 중단하고 옛 버전으로 되돌린다. 사람이 지켜보지 않아도 나쁜 버전이 모든 파드로 퍼지지 않게 하는 장치다.
서비스 메시나 Ingress의 가중치 기능 없이 파드 수로 비율을 나누는 기본 카나리다: 앱 Service가 두 버전의 파드를 함께 고르고, 요청은 파드 수의 비율로 나뉜다.

```
파드 템플릿을 바꾸는 커밋(dev 이미지 태그 등) → ArgoCD 동기화 → Rollout의 파드 템플릿이 바뀐다
  → 0단계 setWeight 50: 새 버전의 ReplicaSet(카나리)을 만들어 파드를 카나리 절반·stable 절반으로 맞춘다. 카나리 파드가 Ready가 되어야 다음 단계로 간다
       파드 2개(dev, 평소의 prod) → 카나리 1·stable 1 / prod가 HPA로 3개면 → 카나리 2·stable 2(maxSurge 1로 하나를 더 띄운다)
  → 1단계 pause 1m: 재지 않고 1분 기다린다. 카나리 파드가 받은 요청이 분석 쿼리의 1분 창을 채우는 시간이다
  → 2단계 analysis: 분석(AnalysisRun)이 30초 간격으로 4번(약 1분 30초) 카나리 파드의 최근 1분 5xx 비율을 잰다. 분석이 성공으로 끝나야 다음으로 간다
  → 전체 승격: 카나리를 전체 파드 수로 늘리고 stable을 내린다 (정상 버전은 카나리 파드가 Ready가 되고 약 2분 30초 뒤)
  분석이 실패하면(5% 이상인 측정이 2번. 처음 두 측정이 실패하면 2단계가 시작되고 약 30초 뒤), 또는 어느 단계에서든 배포가 5분 동안 나아가지 못하면
  (카나리 파드가 Ready가 되지 못한다. pause·analysis 단계에 머무는 시간은 세지 않는다) 중단(abort) → stable을 원래 수로 다시 늘리고 카나리 파드를 내린다
```

- 차트: 단계는 `charts/shortener/templates/rollout.yaml`, 분석의 쿼리와 판정은 `analysistemplate.yaml`, 파드 템플릿은 Deployment와 함께 쓰는 `_helpers.tpl`의 `shortener.appPodTemplate`이다.
  클러스터가 Rollout·AnalysisTemplate kind를 모르면(Argo Rollouts 설치 전, 로컬 k3d) 차트는 지금까지처럼 Deployment를 만든다.
- 파드 템플릿 밖의 변경(Service, Ingress 등)은 카나리 없이 동기화되자마자 반영된다. dev의 이미지 태그 커밋은 매번 카나리를 거치므로 dev 반영이 2분 30초 남짓 늦어진다.
- Rollout을 처음 만들 때(아래 "Deployment에서 옮기기")와 stable과 같은 파드 템플릿으로 되돌릴 때는 단계 없이 바로 그 버전을 전체로 띄운다.

### 분석이 재는 것

쿼리는 카나리 파드가 받은 요청(`/actuator`로 시작하는 요청 제외) 가운데 5xx의 비율이다(창 1분). 카나리 파드는 레이블 `rollouts_pod_template_hash`로 고른다:
Argo Rollouts가 파드마다 붙이는 `rollouts-pod-template-hash`(파드 템플릿의 해시)를 ServiceMonitor의 `podTargetLabels`가 수집한 계열에 옮겨 붙인 것이고,
AnalysisRun을 만들 때 Argo Rollouts가 카나리 ReplicaSet의 해시를 쿼리에 채운다. 그래서 stable 파드의 요청은 섞이지 않는다.
판정은 `successCondition: len(result) == 0 || isNaN(result[0]) || result[0] < 0.05`다.

| 카나리 파드의 상태 | 쿼리 결과 | 판정 |
|---|---|---|
| 최근 1분 요청 중 5xx가 5% 미만 | 0 이상 0.05 미만 | 성공 |
| 최근 1분 요청 중 5xx가 5% 이상 | 0.05 이상 | 실패. 2번째 실패에서 중단(`failureLimit: 1`, 연달아일 필요는 없다) |
| 요청을 받은 적은 있지만 최근 1분에는 없다 | NaN (0 ÷ 0) | 성공 |
| 요청을 받은 적이 없다, 또는 처음 수집된 지 30초가 안 됐다 | 빈 결과 | 성공 |
| Prometheus에 닿지 않는다 | 측정 오류 | 5번 이어지면 중단 |

- **요청이 없으면 통과한다.** 판단할 근거가 없어서다. 조건에 적지 않으면 NaN은 실패로, 빈 결과는 측정 오류로 세어져 요청이 없는 dev의 배포가 중단된다.
  대가로 카나리 동안 요청이 없으면 나쁜 버전도 통과한다. dev에는 평소 요청이 거의 없으므로 아래 연습에서는 카나리 동안 요청을 흘린다.
  같은 이유로 카나리 파드의 메트릭이 수집되지 않거나 `rollouts_pod_template_hash`가 붙지 않으면 분석은 늘 통과한다. 처음 띄운 뒤 Prometheus에서
  `count by (rollouts_pod_template_hash) (up{namespace="shortener-dev", job="shortener-dev"})`가 파드의 해시마다 나오는지 확인한다.
- **측정은 1분 대기 뒤에 시작한다.** 새 카나리 파드는 수집되고 30초쯤 지나야(1분 창에 표본이 2개) 값이 나오고, 그 전에 잰 측정은 빈 결과라 무엇이 오든 성공이다.
  그래서 1단계에서 1분을 기다린 뒤 2단계에서 30초 간격으로 4번(`count: 4`) 잰다. 4번째 측정이 끝나면(약 1분 30초) 분석이 끝나고, 실패가 한 번 이하면 승격한다.
  예전 설정(2분 대기와 나란히 도는 백그라운드 분석)에서는 대기가 시작되자마자 쟀기 때문에 처음 두 측정이 빈 결과였고(v2 연습의 정상 카나리에서도 `[]`, `[]`, 그다음부터 `[0]`), 나쁜 버전도 3·4번째 측정에서야 잡혔다.
  게다가 백그라운드 분석은 승격을 기다리게 하지 않아서, 대기가 끝나면 분석이 아직 판정하지 못했어도 승격했다. 자세한 이유는 `rollout.yaml` 머리말의 [분석]에 있다.
- 분석은 승격 앞에서 끝난다. 카나리를 전체로 늘리는 몇십 초와 그 뒤는 SLO 경보와 앱 파드 경보(위 "SLO 경보가 울리지 않는 장애")가 본다.
- 이웃한 두 측정의 1분 창은 30초씩 겹친다. 그래서 30초보다 짧은 5xx 몰림 하나도 두 측정에 함께 잡혀 중단될 수 있다(`failureLimit: 1`이 봐주는 것은 측정 한 번의 실패다).
- 쿼리는 CI의 "카나리 분석 쿼리 검사" 단계가 promtool로 시험한다(`tests/canary/analysis.test.yaml`). 판정 식은 Argo Rollouts의 식(expr)이라 CI에서는 시험하지 않는다
  (Argo Rollouts v1.10.0과 같은 expr 라이브러리 v1.17.7로 빈 결과·NaN·0.0499·0.05·0.5를 넣어 위 표대로 나오는 것을 확인했다).

### 지켜보기

```bash
kubectl -n argo-rollouts port-forward svc/argo-rollouts-dashboard 3100:3100   # http://localhost:3100/rollouts → 위쪽에서 네임스페이스 shortener-dev를 고른다
kubectl -n shortener-dev get rollout,replicaset,analysisrun
kubectl -n shortener-dev get pods -L rollouts-pod-template-hash,app.kubernetes.io/version
kubectl -n shortener-dev get analysisrun -o yaml   # status.metricResults[].measurements[]: 측정마다의 값(value)과 판정(phase)
```

- 대시보드는 Rollout의 단계, 카나리·stable ReplicaSet의 파드, 분석의 측정을 한 화면에 보여 준다. Rollout 쓰기 권한을 뺐으므로 승격·중단 버튼은 forbidden으로 실패한다(위 "Argo Rollouts (컨트롤러·대시보드)").
- ArgoCD UI에서는 `shortener-<환경>` Application의 트리에서 Rollout 아래에 ReplicaSet과 AnalysisRun이 달린다. 1분 대기 중의 Rollout은 `Suspended`(Argo Rollouts의 `Paused`)로, 분석 단계 동안은 `Progressing`(메시지 `more replicas need to be updated`)으로 보이고, 둘 다 정상이다.
  분석 단계의 AnalysisRun 이름은 `<Rollout>-<카나리 해시>-<리비전>-2`(끝이 단계 번호)이고, Rollout의 `status.canary.currentStepAnalysisRunStatus`에 그 이름과 상태가 있다.

### 중단되면 ArgoCD에서 이렇게 보인다

나쁜 버전은 두 가지 길로 중단되고, 둘 다 Git에서 `git revert`로 되돌린다(아래).

- **5xx를 내는 버전 → 분석이 중단한다.** Rollout의 건강 상태가 `Degraded`이고 메시지는 `RolloutAborted: Rollout aborted update to revision <N>: Step-based analysis phase error/failed: Metric "error-rate" assessed Failed due to failed (2) > failureLimit (1)`이다
  (백그라운드 분석을 쓰던 때는 `Background analysis phase ...`였다).
  그 아래 AnalysisRun도 `Degraded`(Failed)이고, 측정값은 위 `kubectl get analysisrun -o yaml`에 남는다. Application의 Health도 `Degraded`가 된다.
- **Ready가 되지 못하는 버전(시작 실패, CrashLoopBackOff) → 진행 기한이 중단한다.** 0단계에서 멈춰 분석이 시작되지 않으므로, Rollout의 `progressDeadlineSeconds: 300`·`progressDeadlineAbort: true`가
  5분 뒤 중단한다(메시지 `RolloutAborted: Rollout aborted update to revision <N>: ReplicaSet "<이름>" has timed out progressing.`). 그동안 stable은 파드를 줄이지 않아 요청을 그대로 받는다.
- Sync는 `Synced` 그대로다. 클러스터의 Rollout 스펙은 Git(나쁜 버전)과 같고 중단은 Rollout의 status에만 기록되기 때문이다. 그래서 selfHeal도 아무것도 하지 않는다.
- 요청은 stable(옛 버전) 파드가 받는다. 다만 중단 직후 stable을 원래 수로 다시 띄우는 동안(JVM이 뜨는 수십 초)은 카나리 파드도 요청을 받아 오류가 조금 더 이어진다(maxUnavailable 0).
- Rollout은 Git이 바뀔 때까지 중단된 채다. 파드 템플릿을 바꾸는 다음 커밋(dev에 오는 새 이미지 태그 등)이 오면 다시 카나리를 시작하는데, 나쁜 변경이 그대로 남아 있으면 다시 중단된다.
- **되돌리기는 Git에서 한다.** 나쁜 변경의 커밋을 `git revert`한다(위 "롤백"의 절차). 파드 템플릿이 stable과 같아지면 Argo Rollouts는 단계 없이 stable로 돌아가고
  (이벤트 `SkipSteps`: `Rollback to stable ReplicaSets`) Rollout과 Application이 `Healthy`가 된다. 고친 버전을 올리면(fix forward) 그 버전이 새 카나리로 올라간다.
  kubectl 플러그인의 retry는 같은 나쁜 버전을 다시 올릴 뿐이고, ArgoCD의 Rollback은 자동 동기화와 함께 쓸 수 없다(위 "롤백").

### 연습: 나쁜 버전이 저절로 되돌아가는지 본다 (dev)

장애 주입 기능이 들어간 앱 이미지가 dev에 떠 있어야 한다(그 전 이미지는 `SHORTENER_FAULT_ERROR_RATE`를 읽지 않아서 카나리가 그대로 통과한다).

```bash
git switch main && git pull
git switch -c drill/bad-canary
yq -i '.fault.errorRate = "0.5"' environments/dev/values.yaml   # 카나리 파드만 요청의 절반에 500을 돌려준다
git diff                                                      # 한 줄만 바뀌어야 한다
git commit -am "drill(dev): 장애 주입 0.5로 나쁜 버전을 흉내 낸다"
git push -u origin HEAD
gh pr create --fill                                            # validate가 통과하면 머지한다
```

1. 머지하면 ArgoCD가 dev를 동기화하고 카나리가 시작된다. 카나리 동안 dev에 요청을 흘린다(앱 저장소 `loadtest/`의 k6, 또는 리다이렉트를 되풀이하는 curl).
2. 1분 대기 뒤 분석 단계의 처음 두 측정이 실패해(카나리 파드가 Ready가 되고 약 1분 30초 뒤) Rollout이 중단되고(위), 카나리 파드가 내려가 stable 파드만 남는다. 그동안 카나리가 받은 요청의 절반이 500이다(장애 주입의 500은 `uri="UNKNOWN"`으로 기록된다).
3. 그 커밋을 `git revert`하는 PR을 머지해 Git을 되돌린다. Rollout이 단계 없이 `Healthy`가 된다.

### Deployment에서 옮기기 (처음 한 번)

Argo Rollouts가 설치된 클러스터에 이 차트가 처음 반영되는 동기화에서 앱의 Deployment가 Rollout으로 바뀐다(Argo Rollouts가 나중에 설치되면 ArgoCD가 다시 렌더링하는 그때 바뀐다).

- ArgoCD는 AnalysisTemplate을 먼저 만들고(sync-wave -1. 이유는 `analysistemplate.yaml` 머리말) 그다음 Rollout·HPA 등을 적용한다. 새 Rollout은 stable이 없어서 단계 없이 첫 버전을 전체로 띄운다
  (dev는 2개, prod는 1개로 시작해 HPA가 2개로 늘린다).
- 옛 Deployment는 Git에서 사라졌지만 `PruneLast=true`(`argocd/apps/shortener-<환경>.yaml`) 때문에 Rollout이 `Healthy`가 된 뒤에야 지워진다. 그 사이에는 앱 Service가 셀렉터가 같은
  두 쪽 파드에 요청을 나눈다. 두 쪽은 서로의 파드를 가져가지 않는다(각자 만든 ReplicaSet만 관리한다).
- **prod는 요청이 끊기지 않고 옮겨진다. dev는 잠깐 끊긴다.** dev는 같은 동기화에서 PostgreSQL의 인자(`max_connections` 30 → 50)도 바뀌어 StatefulSet이 PostgreSQL 파드를 다시 띄우므로,
  그동안(수십 초) DB를 쓰는 요청이 실패한다. readiness는 DB를 보지 않아서 파드는 Ready로 남고(캐시된 리다이렉트는 응답한다), DB가 필요한 요청만 5xx가 된다.
- HPA는 Rollout을 가리키게 바뀌고, 옛 Deployment의 파드 수는 지워질 때까지 그대로다. prod가 부하로 3개까지 늘어난 채 옮기면 잠깐 앱 파드가 6개(커넥션 60개)까지 떠서
  PostgreSQL 예산(일반 계정 57개)을 넘을 수 있으므로 부하가 없을 때 옮긴다.
- 이 동기화는 지우기 전에 리소스가 `Healthy`가 되기를 기다리다가 그중 하나가 잠깐 `Degraded`로 보이면 실패로 끝난다. 그래도 Deployment는 지워지지 않은 채 요청을 받고,
  자동 동기화의 재시도가 이어서 끝낸다(재시도를 다 쓰고도 멈춰 있으면 UI에서 Sync를 한 번 누른다).
- 옮기는 동안 `kubectl -n shortener-dev get deploy,rollout,pods -L rollouts-pod-template-hash -w`로 Rollout의 파드가 Ready가 된 뒤에 Deployment의 파드가 내려가는지 본다.

### 예산 (파드·커넥션)

| | 평소 앱 파드 | 카나리 중 최대 | 커넥션 최대(파드마다 10개) | PostgreSQL `max_connections` (일반 계정의 몫) |
|---|---|---|---|---|
| dev | 2 | 3 | 30 + 겹침 10 | 50 (47) |
| prod | 2~3 (HPA) | 4 (3개면 카나리 2·stable 2가 대기와 분석 약 2분 30초 동안 이어진다) | 40 + 겹침 10 | 60 (57) |

- 늘어나는 파드는 롤링 업데이트와 같은 하나(maxSurge 1, maxUnavailable 0)다. prod가 3개일 때 그 상태가 대기와 분석(약 2분 30초) 동안 이어진다는 것만 달라서 메모리 최악(위 "메모리 메모")은 같은 숫자다.
- 겹침은 내려가는 파드가 풀을 닫기 전에(preStop 5초 + 종료 최대 20초) 다음 파드가 풀을 여는 몫이다. 계산은 `environments/<환경>/values.yaml`의 `postgresql` 위 주석에 있다.

### 로컬에서 확인하기

CI 단계의 스크립트를 그대로 꺼내 돌린다. 위 "로컬에서 검증하기"에서 읽은 변수를 쓰고, GitHub가 넣어 주는 `RUNNER_TEMP`·`GITHUB_WORKSPACE`는 대신 준다(`yq`와 Docker가 필요하다):

```bash
export KUBERNETES_VERSION KUBECONFORM_IMAGE K8S_SCHEMA_LOCATION CRD_SCHEMA_LOCATION PROMETHEUS_IMAGE
export RUNNER_TEMP=$(mktemp -d) GITHUB_WORKSPACE=$PWD
for step in "렌더링 + 쿠버네티스 스키마 검사 (dev, prod × Rollout, Deployment)" "앱 워크로드 두 갈래 확인 (Rollout, Deployment)" \
            "SLO 규칙 검사 (promtool check + test)" "카나리 분석 쿼리 검사 (promtool check + test)"; do
  bash -e -c "$(yq ".jobs.validate.steps[] | select(.name == \"$step\") | .run" .github/workflows/validate.yml)" || break
done
```

렌더링 결과는 `$RUNNER_TEMP/<환경>.yaml`(Rollout 갈래)과 `$RUNNER_TEMP/<환경>-deployment.yaml`(Deployment 갈래)에 남는다. 카나리 분석 테스트의 시나리오와 읽는 법은 `tests/canary/analysis.test.yaml`의 머리말에 있다.
