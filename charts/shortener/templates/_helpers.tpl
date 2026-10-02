{{- /*
이 파일은 쿠버네티스 리소스를 만들지 않고, 다른 템플릿이 include로 가져다 쓰는 이름·레이블·값 계산 함수만 모아 둔다
(이름이 _로 시작하는 파일은 Helm이 매니페스트로 렌더링하지 않는다).
이 차트의 템플릿 파일 주석은 YAML의 # 주석이 아니라 Go 템플릿 주석(중괄호 두 개 + 슬래시·별표)으로 쓴다.
# 주석은 렌더링 결과(helm template 출력, 클러스터에 저장되는 릴리스 기록)에 그대로 남지만, 템플릿 주석은 남지 않는다.
*/ -}}

{{- /* 차트 이름. 레이블 값은 63자를 넘을 수 없다. */}}
{{- define "shortener.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- /*
모든 리소스 이름의 접두사. nameOverride·fullnameOverride가 없으면 릴리스 이름이 된다
(릴리스 이름에 차트 이름이 이미 들어 있으면 그대로, 아니면 <릴리스>-<차트>).
41자로 자르는 이유: 여기에 접미사를 붙인 이름들이 쿠버네티스의 길이 한계 안에 들어오게 하려는 것이다.
  - StatefulSet 이름(<접두사>-postgresql, 11자)은 52자 이하여야 한다. 컨트롤러가 파드에 붙이는 레이블 controller-revision-hash의 값이
    <StatefulSet 이름>-<해시 최대 10자>인데, 레이블 값은 63자를 넘을 수 없기 때문이다.
  - headless Service 이름(<접두사>-postgresql-headless, 20자)은 DNS 레이블 한계인 63자 이하여야 한다.
*/}}
{{- define "shortener.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 41 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 41 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 41 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- /* helm.sh/chart 레이블 값: 차트 이름과 버전. 레이블 값에는 +를 쓸 수 없어서 _로 바꾼다. */}}
{{- define "shortener.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- /*
셀렉터 레이블: Deployment·StatefulSet의 selector와 Service의 selector가 파드를 고르는 데 쓴다.
한 릴리스 안에 앱·PostgreSQL·Redis 파드가 함께 있으므로 component 레이블이 있어야 서로를 구분한다.
(없으면 앱 Service가 PostgreSQL·Redis 파드까지 골라서, 요청이 엉뚱한 파드로 간다.)
Deployment와 StatefulSet의 selector는 만든 뒤에 바꿀 수 없어서, 값이 바뀔 수 있는 레이블(버전, 차트 버전)은 여기에 넣지 않는다.
인자: dict "ctx" <최상위 컨텍스트 .> "component" <app|postgresql|redis|test>
*/}}
{{- define "shortener.selectorLabels" -}}
app.kubernetes.io/name: {{ include "shortener.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- /*
리소스에 붙이는 표준 레이블(app.kubernetes.io/*): 셀렉터 레이블에 차트 버전, 관리 도구, 소속 앱을 더한 것이다.
version은 넘겼을 때만 붙인다. 앱 Deployment에는 배포할 이미지 태그(커밋 SHA)를 넘긴다. 다만 이것은 Deployment 리소스의 레이블이라 "배포하려는" 버전이고,
파드마다 실제로 떠 있는 커밋은 파드 템플릿에 따로 붙인 version 레이블로 본다(deployment.yaml, kubectl get pods -L app.kubernetes.io/version).
인자: dict "ctx" <.> "component" <...> ["version" <값>]
*/}}
{{- define "shortener.labels" -}}
helm.sh/chart: {{ include "shortener.chart" .ctx }}
{{ include "shortener.selectorLabels" . }}
app.kubernetes.io/part-of: shortener
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
{{- with .version }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
{{- end }}

{{- /*
앱 이미지 참조(repository:tag). 태그는 커밋 SHA 전체(16진수 40자)만 받고, 그 밖의 값이면 여기서 템플릿이 실패한다.
latest처럼 가리키는 이미지가 바뀌는 태그나 빈 태그로 배포하면 "지금 뭐가 떠 있나", "어디로 되돌리나"에 답할 수 없어서다.
SHA 형식만 보고 GHCR에 그 태그가 실제로 있는지는 확인하지 않는다(없으면 파드가 ImagePullBackOff가 된다).
toString은 숫자로만 된 태그를 Helm이 정수로 읽는 경우(--set image.tag=1234567)에 %s가 깨지지 않게 하려는 것이다.
*/}}
{{- define "shortener.appImage" -}}
{{- $tag := required "image.tag가 비어 있다. 배포할 이미지의 커밋 SHA(40자)를 넣어야 한다: --set image.tag=<커밋 SHA 40자>" .Values.image.tag | toString -}}
{{- if not (regexMatch "^[0-9a-f]{40}$" $tag) -}}
{{- fail (printf "image.tag는 커밋 SHA 전체(소문자 16진수 40자)여야 한다. 받은 값: %q. latest 같은 움직이는 태그는 쓰지 않는다: 배포 하나가 커밋 하나에 정확히 대응해야 한다" $tag) -}}
{{- end -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end }}

{{- /* DB 비밀번호가 든 Secret의 이름: 기존 Secret을 쓰면 그 이름, 아니면 차트가 만드는 Secret의 이름 */}}
{{- define "shortener.dbSecretName" -}}
{{- .Values.database.existingSecret | default (printf "%s-database" (include "shortener.fullname" .)) -}}
{{- end }}

{{- /* 앱이 접속할 DB 주소: 직접 지정한 값, 없으면 이 릴리스의 PostgreSQL Service. 내부 DB를 껐는데 주소도 없으면 실패한다. */}}
{{- define "shortener.dbHost" -}}
{{- if .Values.database.host -}}
{{- .Values.database.host -}}
{{- else if .Values.postgresql.enabled -}}
{{- printf "%s-postgresql" (include "shortener.fullname" .) -}}
{{- else -}}
{{- fail "postgresql.enabled=false이면 접속할 외부 DB의 주소(database.host)를 넣어야 한다" -}}
{{- end -}}
{{- end }}

{{- /* 앱이 접속할 Redis 주소: 직접 지정한 값, 없으면 이 릴리스의 Redis Service. 내부 Redis를 껐는데 주소도 없으면 실패한다. */}}
{{- define "shortener.redisHost" -}}
{{- if .Values.redis.host -}}
{{- .Values.redis.host -}}
{{- else if .Values.redis.enabled -}}
{{- printf "%s-redis" (include "shortener.fullname" .) -}}
{{- else -}}
{{- fail "redis.enabled=false이면 접속할 외부 Redis의 주소(redis.host)를 넣어야 한다" -}}
{{- end -}}
{{- end }}

{{- /*
앱의 비밀이 아닌 환경 변수(ConfigMap의 data). 비밀번호(DB_PASSWORD)는 Secret에서 따로 주입한다.
ConfigMap의 값은 문자열이어야 해서 숫자도 quote로 감싼다.
ConfigMap 템플릿과 Deployment의 체크섬 어노테이션이 이 한 곳을 함께 쓴다: 체크섬이 ConfigMap 전체가 아니라 이 데이터만 해시하므로
레이블(차트 버전 등)이 바뀌는 것만으로는 파드가 재시작되지 않는다.
*/}}
{{- define "shortener.configData" -}}
DB_HOST: {{ include "shortener.dbHost" . | quote }}
DB_PORT: {{ .Values.database.port | quote }}
DB_NAME: {{ .Values.database.name | quote }}
DB_USERNAME: {{ .Values.database.username | quote }}
REDIS_HOST: {{ include "shortener.redisHost" . | quote }}
REDIS_PORT: {{ .Values.redis.port | quote }}
SHORTENER_BASE_URL: {{ .Values.baseUrl | quote }}
SHORTENER_CACHE_TTL: {{ .Values.cacheTtl | quote }}
{{- end }}

{{- /*
지연 SLO의 기준(slo.latency.thresholdSeconds)을 히스토그램 le 레이블의 값으로 바꾼다. PromQL의 le="..." 매처는 문자열을 글자 그대로 비교하므로
Prometheus에 저장된 값과 정확히 같아야 한다. Prometheus 3은 수집할 때 le 값을 OpenMetrics의 실수 표기로 정규화해 저장한다: 0.3은 "0.3", 1은 "1.0"이다.
Helm은 값 파일의 1(1.0으로 적어도 마찬가지다)을 "1"로 출력하므로, 소수점도 지수 표기(e)도 없으면 ".0"을 붙여 저장된 값과 맞춘다.
*/}}
{{- define "shortener.sloLatencyLe" -}}
{{- $le := .Values.slo.latency.thresholdSeconds | toString -}}
{{- if not (regexMatch "[.e]" $le) -}}
{{- $le = printf "%s.0" $le -}}
{{- end -}}
{{- $le -}}
{{- end }}

{{- /*
SLO 번 레이트 알림의 조건식(PromQL). 가용성·지연 알림이 같은 식을 쓴다. 이 모양의 이유는 prometheusrule.yaml 머리말의 [번 레이트]·[다중 창]에 있다.
기준은 미리 계산한 숫자가 아니라 "14.4 * (1 - 99.5 / 100)"처럼 목표에서 PromQL이 계산하게 적는다: 식에 목표가 그대로 보이고, 목표를 바꾸면 기준도 함께 바뀐다.
and·or는 양쪽에서 레이블(namespace, job)이 같은 시계열끼리 짝짓는다. 식의 값은 or의 왼쪽(1시간 비율)이 있으면 그것이고, 없으면 오른쪽(6시간 비율)이다.
인자: dict "record" <기록 규칙 이름 중 :ratio_rate<창> 앞부분> "namespace" <네임스페이스> "job" <job> "objective" <목표(%)>
*/}}
{{- define "shortener.sloBurnRateAlertExpr" -}}
(
  {{ .record }}:ratio_rate1h{namespace="{{ .namespace }}", job="{{ .job }}"} > (14.4 * (1 - {{ .objective }} / 100))
  and
  {{ .record }}:ratio_rate5m{namespace="{{ .namespace }}", job="{{ .job }}"} > (14.4 * (1 - {{ .objective }} / 100))
)
or
(
  {{ .record }}:ratio_rate6h{namespace="{{ .namespace }}", job="{{ .job }}"} > (6 * (1 - {{ .objective }} / 100))
  and
  {{ .record }}:ratio_rate30m{namespace="{{ .namespace }}", job="{{ .job }}"} > (6 * (1 - {{ .objective }} / 100))
)
{{- end }}

{{- /*
앱을 Deployment 대신 Argo Rollouts의 Rollout으로 배포할지. 참이면 "true", 아니면 빈 문자열을 돌려준다(include의 결과는 문자열이라 if는 빈 문자열만 거짓으로 본다).
rollout.enabled가 켜져 있고 클러스터가 Rollout과 AnalysisTemplate 두 kind를 모두 알 때만 참이다. 조건의 이유는 rollout.yaml 머리말의 [조건부 생성]에 있다.
deployment.yaml·rollout.yaml·analysistemplate.yaml·hpa.yaml이 이 한 곳을 함께 써서, Deployment와 Rollout이 함께 나오거나 함께 빠지는 일이 없고 HPA가 늘 있는 쪽을 가리킨다.
*/}}
{{- define "shortener.rolloutEnabled" -}}
{{- if and .Values.rollout.enabled (.Capabilities.APIVersions.Has "argoproj.io/v1alpha1/Rollout") (.Capabilities.APIVersions.Has "argoproj.io/v1alpha1/AnalysisTemplate") -}}
true
{{- end -}}
{{- end }}

{{- /*
장애 주입 비율(fault.errorRate)을 환경 변수 값으로 돌려준다. 0 이상 1 이하의 소수(예: "0", "0.05", "1")만 받고, 비어 있거나 그 밖의 값이면 여기서 템플릿이 실패한다.
앱은 빈 값이나 범위 밖의 값을 받으면 시작할 때 설정 검증에서 실패해서, 그 값으로 배포하면 파드가 재시작을 되풀이한다(50%를 뜻하고 50을 적는 실수 같은 것).
그 전에 렌더링(validate, ArgoCD)에서 걸리게 하려는 것이다. toString은 따옴표 없이 적은 숫자(0.5)도 받으려는 것이다.
*/}}
{{- define "shortener.faultErrorRate" -}}
{{- $rate := required "fault.errorRate가 비어 있다. 장애를 넣지 않으려면 \"0\"을 적는다" .Values.fault.errorRate | toString -}}
{{- if not (regexMatch "^(0(\\.[0-9]+)?|1(\\.0+)?)$" $rate) -}}
{{- fail (printf "fault.errorRate는 0 이상 1 이하의 소수여야 한다(예: \"0.5\"는 요청의 50%%). 받은 값: %q" $rate) -}}
{{- end -}}
{{- $rate -}}
{{- end }}

{{- /*
앱 파드 템플릿(metadata·spec). Deployment(deployment.yaml)와 Rollout(rollout.yaml)이 이 한 곳을 함께 쓴다: 어느 워크로드로 배포되든 파드가 같고,
한쪽만 고쳐서 둘이 어긋나는 일이 없다(validate 워크플로가 두 렌더링 결과의 파드 템플릿이 같은지도 비교한다).
설정은 ConfigMap(envFrom)과 Secret(DB_PASSWORD)의 환경 변수로 받고, 8080(http)은 서비스 트래픽, 8081(management)은 actuator 전용 포트다.
*/}}
{{- define "shortener.appPodTemplate" -}}
metadata:
  {{- /*
  파드 템플릿에 설정의 해시를 어노테이션으로 넣는다. envFrom·secretKeyRef로 주입한 환경 변수는 컨테이너가 시작될 때 한 번만 읽히고,
  그 뒤에 ConfigMap이나 Secret을 고쳐도 실행 중인 파드의 환경 변수는 바뀌지 않는다(볼륨으로 마운트한 파일과 다르다).
  해시가 들어 있으면 설정이 바뀔 때 파드 템플릿이 달라져서, Deployment(롤링 업데이트)나 Rollout(카나리)이 새 설정을 읽는 파드를 새로 띄운다.
  Secret은 차트가 만들 때만 해시를 넣는다. 기존 Secret(existingSecret)의 내용은 helm template·ArgoCD 같은 렌더링에서 읽을 수 없어서다(values.yaml의 existingSecret 설명 참고).
  */}}
  annotations:
    checksum/config: {{ include "shortener.configData" . | sha256sum }}
    {{- if not .Values.database.existingSecret }}
    checksum/secret: {{ .Values.database.password | toString | sha256sum }}
    {{- end }}
  {{- /*
  파드 레이블: 셀렉터 레이블에 이미지 태그(커밋 SHA)를 version 레이블로 더한다. 셀렉터(Deployment·Rollout의 spec.selector)에는 넣지 않는다.
  Deployment의 셀렉터는 만든 뒤에 바꿀 수 없어서, 배포마다 바뀌는 값을 넣으면 다음 helm upgrade(ArgoCD에서는 동기화)가 거부된다. 파드 레이블은 바뀌어도 되므로 여기에만 둔다.
  그래서 kubectl get pods -L app.kubernetes.io/version으로 파드마다 실제로 어느 커밋이 떠 있는지 보인다(롤링 업데이트·카나리 중에는 두 SHA가 섞여 보인다).
  레이블 값은 63자를 넘을 수 없는데, 커밋 SHA는 40자라 그대로 들어간다.
  */}}
  labels:
    {{- include "shortener.selectorLabels" (dict "ctx" . "component" "app") | nindent 4 }}
    app.kubernetes.io/version: {{ .Values.image.tag | toString | trunc 63 | quote }}
spec:
  serviceAccountName: {{ include "shortener.fullname" . }}
  automountServiceAccountToken: false
  {{- /*
  기본값(true)이면 kubelet이 같은 네임스페이스의 모든 Service마다 <이름>_PORT, <이름>_SERVICE_HOST 같은 환경 변수를 파드에 넣는다.
  Service 이름이 shortener이면 SHORTENER_PORT=tcp://... 가 생기는데, 이 이름은 앱 설정의 접두사(shortener.*, 환경 변수 SHORTENER_*)와 같은 영역이다.
  서비스를 찾는 데는 DNS를 쓰므로 필요 없어서 끈다.
  */}}
  enableServiceLinks: false
  {{- /*
  종료 유예 시간. 파드를 지우면 이 시간의 카운트다운이 (preStop이 시작되기 전에) 먼저 시작되고, 시간이 다 되면 kubelet이 SIGKILL로 강제 종료한다.
  preStop에서 기다리는 시간도 이 안에 든다: preStop 5초 + 앱의 graceful shutdown 최대 20초(application.yml의 spring.lifecycle.timeout-per-shutdown-phase)
  = 25초라서 30초 안에 끝나고, 남는 5초는 JVM이 종료를 마무리하는 여유다. 앱의 종료 시간을 늘리면 이 값도 함께 늘려야 한다.
  */}}
  terminationGracePeriodSeconds: 30
  {{- /*
  파드 수준 보안 설정: 이 값은 파드의 모든 컨테이너에 적용된다.
  - runAsNonRoot: kubelet이 컨테이너를 시작할 때 실제 UID를 확인해서 0(root)이면 시작을 거부한다.
  - runAsUser·runAsGroup: Dockerfile의 USER 10001:10001과 같은 숫자 ID다. runAsGroup을 빼면 기본 그룹을 런타임이 정하는데(쿠버네티스 문서에는 root 그룹 0으로 적혀 있다),
    명시해서 이미지의 계정과 어긋나지 않게 한다.
  - seccompProfile RuntimeDefault: seccomp는 프로세스가 쓸 수 있는 시스템 콜을 거르는 커널 기능이다. 지정하지 않으면(kubelet이 기본값으로 켜 두지 않은 한)
    필터 없이 돈다. RuntimeDefault는 컨테이너 런타임이 기본으로 제공하는 프로필이라서, 컨테이너에 필요 없는 위험한 시스템 콜을 막는다.
  */}}
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: shortener
      image: {{ include "shortener.appImage" . | quote }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      ports:
        - name: http
          containerPort: 8080
        - name: management
          containerPort: 8081
      envFrom:
        - configMapRef:
            name: {{ include "shortener.fullname" . }}
      env:
        {{- /*
        Spring Boot의 완화된 바인딩(relaxed binding)이 MANAGEMENT_SERVER_PORT를 management.server.port로 읽어서 actuator 엔드포인트를 8081로 옮긴다.
        아래 containerPort(management)와 같은 번호여야 한다(프로브와 Service는 포트 이름 management로 가리키므로 번호를 따로 적지 않는다).
        actuator를 서비스 포트(8080)와 분리하면, Ingress는 http 포트(8080)만 가리키므로 헬스·메트릭 엔드포인트가 클러스터 밖으로 노출되지 않는다.
        */}}
        - name: MANAGEMENT_SERVER_PORT
          value: "8081"
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: {{ include "shortener.dbSecretName" . }}
              key: password
        {{- /*
        장애 주입 비율(values.yaml의 fault.errorRate, 앱 설정 shortener.fault.error-rate): 앱이 서비스 포트(8080)의 요청 중 이 비율에 HTTP 500을 돌려준다. "0"이면 하지 않는다.
        ConfigMap이 아니라 파드 템플릿에 바로 적어서, 값을 바꾼 커밋의 diff에 Rollout의 파드 템플릿이 바뀐 것이 그대로 보인다. 바뀐 템플릿은 카나리로 배포되므로
        카나리 파드만 이 값을 갖는다. 장애 주입 기능이 없는 이전 이미지는 이 환경 변수를 읽지 않는다.
        */}}
        - name: SHORTENER_FAULT_ERROR_RATE
          value: {{ include "shortener.faultErrorRate" . | quote }}
      {{- /*
      --- 프로브 세 가지 (모두 management 포트) ---
      startupProbe: 이 프로브가 성공할 때까지 liveness·readiness 프로브는 실행되지 않는다. JVM 시작이 느린 작은 VM에서도 liveness가
      아직 뜨는 중인 앱을 죽이지 않게 막는 장치다. 2초마다 검사하고 60번 연속 실패하면 컨테이너를 재시작한다
      (뜨는 동안 연결이 바로 거부되는 경우 2초 × 60 = 최대 120초. 응답이 느려 타임아웃으로 실패하면 시도마다 그만큼 더 걸린다).
      liveness의 initialDelaySeconds를 크게 잡는 방식과 달리, 앱이 빨리 뜨면 기다리지 않고 바로 다음 단계로 넘어간다.
      timeoutSeconds 기본값(1초)은 시작 중 CPU를 다 쓰는 JVM에는 짧아서 정상인데도 실패로 세어질 수 있어 3초로 늘렸다(livenessProbe·readinessProbe도 같다).
      */}}
      startupProbe:
        httpGet:
          path: /actuator/health/liveness
          port: management
        periodSeconds: 2
        timeoutSeconds: 3
        failureThreshold: 60
      {{- /*
      livenessProbe: 프로세스가 응답 불능(교착, 무한 루프 등)에 빠졌는지만 본다. 3번 연속 실패하면 kubelet이 컨테이너를 재시작한다.
      앱의 liveness 그룹에는 DB·Redis 같은 외부 의존성이 들어 있지 않다. 외부 장애 때 liveness까지 실패하면 멀쩡한 앱 파드 전부가 재시작을 되풀이해서
      DB가 돌아와도 복구가 더 늦어진다. 외부 의존성은 아래 readiness가 맡는다.
      */}}
      livenessProbe:
        httpGet:
          path: /actuator/health/liveness
          port: management
        periodSeconds: 10
        timeoutSeconds: 3
        failureThreshold: 3
      {{- /*
      readinessProbe: 트래픽을 받을 준비가 됐는지 본다. 실패하면 재시작하지 않고, 이 파드를 Service의 엔드포인트에서 뺀다(성공하면 다시 넣는다).
      앱의 readiness 그룹에는 DB가 들어 있어서, DB가 죽은 동안에는 요청을 받지 않는다. Redis는 죽어도 DB로 버틸 수 있어서 넣지 않았다.
      롤링 업데이트(Rollout의 카나리도 같다)에서는 새 파드가 이 프로브를 통과해야 옛 파드가 내려간다.
      */}}
      readinessProbe:
        httpGet:
          path: /actuator/health/readiness
          port: management
        periodSeconds: 5
        timeoutSeconds: 3
        failureThreshold: 3
      {{- /*
      preStop 훅: 컨테이너에 SIGTERM을 보내기 전에 5초 기다린다 (sleep 액션은 1.34에서 GA다).
      파드를 지우면 두 가지가 동시에 시작된다.
        (가) 엔드포인트 컨트롤러가 이 파드를 Service의 엔드포인트에서 뺀다.
        (나) kubelet이 preStop 훅을 실행하고, 끝나면 컨테이너에 SIGTERM을 보낸다.
      (가)의 결과가 트래픽을 보내는 쪽(여기서는 Traefik이 API 서버에서 엔드포인트 변경을 받아 라우팅을 갱신한다)에 닿기까지는 시간이 걸리고, (나)와의 순서는 보장되지 않는다.
      SIGTERM을 곧바로 받은 앱은 새 요청을 받지 않는데, 그때까지 Traefik이 이 파드로 요청을 보내면 연결이 거부돼 요청이 실패한다.
      5초를 쉬는 동안 앱은 평소처럼 요청을 받고, 엔드포인트 제거가 퍼진 뒤에 SIGTERM이 가서 graceful shutdown이 시작된다.
      sleep 액션은 kubelet이 직접 기다려 주는 내장 훅이라 컨테이너 안에 sleep 실행 파일이 없어도 된다.
      */}}
      lifecycle:
        preStop:
          sleep:
            seconds: 5
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      {{- /*
      컨테이너 수준 보안 설정.
      - allowPrivilegeEscalation false: 프로세스에 no_new_privs를 걸어서, setuid 바이너리 같은 수단으로 부모보다 큰 권한을 얻지 못하게 한다.
      - capabilities drop ALL: 리눅스 capability는 root의 권한을 잘게 쪼갠 것이다. 컨테이너는 기본으로 그중 일부(CHOWN, SETUID, NET_RAW 등)를 갖는데
        이 앱에는 필요한 게 없다(8080은 1024 이상이라 NET_BIND_SERVICE도 필요 없다).
      - readOnlyRootFilesystem: 루트 파일시스템을 읽기 전용으로 마운트해서, 앱이 뚫려도 파일을 심거나 바꿀 수 없게 한다.
        쓰기가 필요한 곳은 볼륨으로 따로 열어 준다(아래 /tmp).
      */}}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    {{- /*
    읽기 전용 루트 파일시스템에서도 JVM과 Tomcat은 /tmp에 쓴다 (Tomcat 작업 디렉터리 tomcat.*, JVM 성능 데이터 디렉터리 hsperfdata_*).
    emptyDir은 파드가 뜰 때 빈 디렉터리로 만들어지고 파드가 사라지면 함께 지워진다. 누구나 쓸 수 있는 권한(0777)으로 만들어져서 UID 10001도 쓸 수 있다.
    sizeLimit은 /tmp 사용량이 폭주해도 노드 디스크를 채우지 않게 하는 상한이다(넘으면 kubelet이 파드를 내쫓는다).
    */}}
    - name: tmp
      emptyDir:
        sizeLimit: 64Mi
{{- end }}
