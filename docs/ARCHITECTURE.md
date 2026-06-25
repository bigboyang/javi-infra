# Javi APM 플랫폼 — 아키텍처 가이드

> 이 문서는 PR 마다 자동 생성/갱신됩니다.

이 문서는 처음 이 레포에 합류한 사람을 위한 풀어쓴 설명서다. AI 에이전트용 간결 가이드는 `CLAUDE.md`를 보라.

## 1. 이 레포가 하는 일

`javi-infra`는 **Javi APM(Application Performance Monitoring) 플랫폼**을 운영하는 Kubernetes 클러스터의 GitOps 인프라 레포다. 이 레포 안에는 애플리케이션 소스 코드가 없다 — 오직 Kubernetes 매니페스트, Kustomize 오버레이, ArgoCD Application 정의, CI 워크플로만 들어있다.

실제 비즈니스 로직(수집기, 예측 엔진, 대시보드, 설정 서버)은 별도 레포(`javi-collector`, `javi-forecast`, `javi-dashboard`, `javi-config-server`)에서 개발되고, 거기서 빌드된 컨테이너 이미지를 이 레포가 "어떻게, 어디에, 어떤 설정으로" 배포할지 선언한다. 즉 이 레포는 클러스터 상태에 대한 단일 진실 공급원(single source of truth)이며, `main` 브랜치에 머지된 내용이 곧 운영 환경의 실제 상태가 된다(ArgoCD가 자동으로 동기화하기 때문).

이렇게 소스 코드와 배포 정의를 분리해 둔 이유는, 인프라 변경(리소스 조정, 네트워크 정책, 시크릿 교체 등)을 애플리케이션 배포 사이클과 독립적으로 리뷰·롤백할 수 있게 하기 위함으로 보인다(README의 구조 설명에서 추정).

## 2. 전체 아키텍처

플랫폼은 OTLP(OpenTelemetry Protocol)로 들어오는 트레이스/메트릭/로그를 수집해 ClickHouse에 저장하고, Kafka를 통해 비동기로 이상 탐지·예측을 수행하며, 그 결과를 대시보드로 보여주는 구조다.

```
                                   ┌─────────────────────────┐
                                   │   nginx Ingress (HTTPS) │
                                   └────────────┬─────────────┘
                     ┌────────────────┬─────────┴──────────┬───────────────────┐
                     │                │                    │                   
              collector.apm.*   dashboard.apm.*      config.apm.*
                     │                │                    │
                     ▼                ▼                    ▼
            ┌─────────────────┐ ┌───────────────┐  ┌────────────────────┐
            │ javi-collector   │ │ javi-dashboard│  │ javi-config-server │
            │ (OTLP 4317/4318) │ │  (UI + API)   │  │  (agent 원격 설정)   │
            └────────┬─────────┘ └──────┬────────┘  └─────────────────────┘
                     │  (kafka produce)  │ (조회 API)
                     ▼                  ▼
            ┌─────────────────┐  HTTP   │
            │  Kafka (Strimzi) │ ◄───────┤  FORECAST_URL
            │  spans.all /     │         │
            │  metrics / logs /│         │
            │  deploys         │         │
            └────────┬─────────┘         │
                     │ (consume,         │
                     │  group: javi-forecast)
                     ▼                  │
            ┌─────────────────┐         │
            │  javi-forecast   │◄────────┘
            │ (이상탐지/예측/RCA)│
            └──┬───────┬───────┘
               │       │
       ClickHouse 읽기/쓰기   Redis (FeatureStore 공유)
               │
               ▼
       ┌─────────────────┐      ┌────────┐      ┌────────┐
       │   ClickHouse     │      │ Qdrant │      │ Ollama │
       │ (시계열/스팬 저장) │      │(벡터DB) │      │(로컬LLM)│
       └─────────────────┘      └────────┘      └────────┘
```

### 컴포넌트별 역할

| 컴포넌트 | 역할 | 비고 |
|---|---|---|
| **javi-collector** | OTLP(gRPC 4317 / HTTP 4318) 트레이스·메트릭·로그 수집, Kafka로 적재 | ClickHouse가 뜬 뒤 시작(initContainer로 대기) |
| **javi-forecast** | Kafka에서 span을 소비해 이상 탐지(AnomalyDetector), 베이스라인 계산(BaselineComputer), 근본원인분석(RCAEngine), 부하 예측 수행 | KEDA로 Kafka consumer lag 기반 오토스케일 (prod) |
| **javi-dashboard** | 웹 UI + 조회용 API 백엔드. ClickHouse·forecast 결과를 사용자에게 노출 | forecast, ClickHouse 준비 대기 후 시작 |
| **javi-config-server** | APM 에이전트가 폴링하는 원격 설정 서버 | `Recreate` 전략(상태 파일 단일 PVC, 동시 두 인스턴스 쓰기 방지 목적으로 추정) |
| **Kafka (Strimzi)** | collector→forecast 사이의 비동기 메시지 버스. 토픽: `spans.all`, `metrics`, `logs`, `deploys`, `spans.dlq`(DLQ) | KRaft 모드, operator 별도 설치 필요 |
| **ClickHouse** | 트레이스/메트릭/로그의 시계열 저장소 | native(9000)/http(8123) 포트, 매일 백업 |
| **Redis** | forecast 멀티 레플리카 간 FeatureStore 공유(캐시) | dev는 단일 Pod, prod는 Sentinel HA로 대체 |
| **Qdrant** | RAG용 벡터 DB | forecast/collector의 LLM 보조 기능에서 사용하는 것으로 추정 |
| **Ollama** | 로컬 LLM 추론(임베딩 `nomic-embed-text`, 채팅 `qwen2.5:1.5b`) | prod는 GPU 노드에만 스케줄 |

## 3. 데이터/요청 흐름

크게 두 가지 흐름이 있다.

**(A) 텔레메트리 수집 → 분석 (쓰기 경로, 비동기)**
1. APM 에이전트(클러스터 밖, 모니터링 대상 애플리케이션에 설치된 라이브러리)가 OTLP로 `collector.apm.*` Ingress를 통해 트레이스/메트릭/로그를 전송한다.
2. `javi-collector`가 이를 받아 Kafka 토픽(`spans.all` 등)에 적재한다.
3. `javi-forecast`가 `javi-forecast` consumer group으로 해당 토픽을 구독해 소비하고, ClickHouse에 가공된 데이터를 쓰며 이상 탐지·예측·RCA를 수행한다. 결과에 따라 Slack/Webhook으로 알림을 보낼 수 있다(`ALERT_SLACK_WEBHOOK_URL`, `ALERT_WEBHOOK_URL`).
4. ClickHouse에 쓰기가 실패한 span은 `spans.dlq` 토픽으로 보내 재처리하는 것으로 보인다(토픽 주석 기준, 실제 DLQ 처리 로직은 `javi-forecast`/`javi-collector` 소스에 있어 이 레포에서는 확인 불가).

**(B) 사용자 조회 (읽기 경로, 동기)**
1. 브라우저가 `dashboard.apm.*` Ingress로 `javi-dashboard`에 접속한다.
2. `javi-dashboard`는 ClickHouse(native 9000 포트)에서 시계열 데이터를 직접 조회하고, 예측/이상탐지 결과는 `javi-forecast`의 HTTP API(`FORECAST_URL=http://javi-forecast:8080`)를 호출해 가져온다.

**(C) 에이전트 설정 폴링**
- 모니터링 대상의 APM 에이전트가 `config.apm.*` Ingress를 통해 `javi-config-server`(포트 18888)에서 원격 설정을 주기적으로 가져간다. 상태는 PVC 위 `STATE_FILE`(JSON)에 보관된다.

## 4. 디렉터리 구조와 책임

```
javi-infra/
├── argocd/                 # ArgoCD Application 정의 — "무엇을 어떤 소스에서 어디로 배포할지"
│   ├── namespace.yaml
│   └── apps/
│       ├── apm-prod-app.yaml     # k8s/overlays/prod → apm 네임스페이스, automated(prune+selfHeal)
│       ├── apm-dev-app.yaml      # k8s/overlays/dev  → apm 네임스페이스, 수동 sync(자동 prune 위험 방지)
│       ├── monitoring-app.yaml   # Helm 차트(kube-prometheus-stack) → monitoring 네임스페이스
│       ├── redis-ha-app.yaml     # Helm 차트(bitnami/redis, Sentinel) → apm 네임스페이스 (prod HA)
│       └── keda-app.yaml         # Helm 차트(KEDA operator) → keda 네임스페이스
├── cert-manager/
│   └── cluster-issuer.yaml       # Let's Encrypt staging/prod ClusterIssuer (HTTP-01)
├── k8s/
│   ├── base/                     # 환경 무관 매니페스트. 직접 배포 금지(overlay 경유 필수)
│   │   ├── kustomization.yaml    # base가 포함하는 모든 리소스 목록(이 파일이 "조립 설명서")
│   │   ├── namespace.yaml        # apm 네임스페이스 + Pod Security Standards(baseline 강제)
│   │   ├── resource-quota.yaml   # 네임스페이스 전체 CPU/메모리/오브젝트 수 예산
│   │   ├── rbac/                 # 서비스별 전용 ServiceAccount (모두 automountServiceAccountToken: false)
│   │   ├── ingress.yaml          # dashboard/config/collector 3개 호스트 라우팅
│   │   ├── network-policy/       # 기본 deny-all + 서비스별 allow 규칙 (제로트러스트 네트워킹)
│   │   ├── clickhouse/, collector/, config-server/, dashboard/, forecast/,
│   │   │   kafka/, ollama/, qdrant/, redis/   # 서비스별 Deployment/StatefulSet/Service/...
│   └── overlays/
│       ├── dev/                  # 단일 레플리카, 축소 리소스, 평문 placeholder secret
│       │   └── patches/          # 서비스별 리소스 다운사이징 patch
│       └── prod/                 # 3-replica Kafka, 영구 스토리지, SealedSecret, KEDA, HTTPS
│           └── patches/          # prod 전용 patch(레플리카 수, GPU, TLS, Redis HA 연결 등)
└── scripts/
    └── seal-secrets.sh           # kubeseal로 평문 시크릿 → SealedSecret 변환 헬퍼
```

**왜 `base`/`overlays`로 나눴는가**: Kustomize의 표준 패턴으로, "무엇을 배포하는가"(base)와 "환경별로 무엇이 다른가"(overlay)를 분리한다. 예를 들어 Kafka 클러스터 정의는 base에 한 번만 쓰고, prod overlay가 JSON6902 patch로 레플리카 수·복제 팩터·스토리지 크기만 바꾼다. 이렇게 하면 dev/prod가 같은 토폴로지를 공유하면서 설정값만 갈라지는 걸 보장할 수 있다.

**왜 NetworkPolicy가 기본 deny인가**: `default-deny.yaml`(ingress 전체 차단)과 `default-deny-egress.yaml`(egress도 차단, DNS/kube-apiserver/같은 네임스페이스만 예외)이 먼저 적용되고, 각 서비스가 필요한 통신만 `allow-*.yaml`로 명시적으로 열어준다. 새 서비스를 추가할 때 이 allow 규칙을 빠뜨리면 Pod이 기동돼도 통신이 막혀 조용히 실패하므로, CLAUDE.md에도 "NetworkPolicy 없이 배포 금지"가 명시돼 있다.

## 5. 로컬 개발 시작법

이 레포 자체에는 빌드할 코드가 없으므로 "로컬 개발"은 곧 "클러스터에 매니페스트를 적용/검증하는 것"을 의미한다.

**필요 도구**
- `kubectl`, `kustomize`(또는 `kubectl kustomize` 내장 기능)
- Strimzi 오퍼레이터(Kafka CRD) — `kubectl create -f 'https://strimzi.io/install/latest?namespace=apm'`
- nginx ingress controller
- (prod만) `kubeseal` CLI + sealed-secrets controller, ArgoCD, cert-manager, KEDA

**자주 쓰는 명령**
```bash
# dev 배포
kubectl apply -k k8s/overlays/dev

# prod 배포 (보통은 ArgoCD가 자동으로 하므로 직접 실행할 일은 적음)
kubectl apply -k k8s/overlays/prod

# 적용 전 검증 (dry-run, 실제 클러스터 변경 없음)
kubectl kustomize k8s/overlays/prod | kubectl apply --dry-run=client -f -

# prod 시크릿 교체 (kubeseal 필요)
./scripts/seal-secrets.sh
```

ArgoCD를 쓰는 일반적인 흐름은 "로컬에서 `kubectl apply`" 가 아니라 "PR을 `main`에 머지 → ArgoCD가 감지해 자동 동기화"다. `apm-prod` Application은 `automated: {prune: true, selfHeal: true}`이므로, 누군가 클러스터를 `kubectl`로 직접 고쳐도 ArgoCD가 Git 상태로 되돌린다. 반면 `apm-dev`는 수동 sync로 설정돼 있어 dev에서는 ArgoCD UI/CLI로 직접 sync를 눌러줘야 한다(자동 prune으로 인한 의도치 않은 리소스 삭제를 막기 위한 것으로 보인다).

## 6. 알아둘 함정·주의사항·트레이드오프

- **base 직접 배포 금지**: `k8s/base/kustomization.yaml`만 보면 이미지 이름이 `javi-collector:latest`처럼 레지스트리 경로 없는 placeholder다. prod overlay가 `images:` 섹션으로 `ghcr.io/bigboyang/...`와 실제 버전 태그로 바꿔준다. base를 그대로 적용하면 이미지를 못 받아온다.
- **prod 이미지 태그는 CI가 관리**: `build-push.yml`의 `update-image-tags` 잡이 빌드 성공 후 `kustomize edit set image`로 `k8s/overlays/prod/kustomization.yaml`을 직접 커밋한다. 사람이 수동으로 태그를 바꾸면 다음 CI 실행 때 덮어써질 수 있다.
- **selfHeal이 수동 kubectl 변경을 되돌린다**: prod에서 디버깅 차원에서 `kubectl edit`/`kubectl patch`로 임시 수정해도 ArgoCD가 곧 원복한다. 변경은 항상 Git에 반영해야 한다.
- **dev secrets는 평문 placeholder**: `k8s/overlays/dev/secrets/*.yaml`은 git에 평문으로 커밋돼 있다(테스트용 값). 실제 자격증명을 여기 넣으면 git 히스토리에 영구히 남는다. prod는 반드시 SealedSecret(`scripts/seal-secrets.sh`로 생성)을 쓴다.
- **HPA와 KEDA ScaledObject 동시 사용 충돌**: prod overlay는 base의 `javi-collector`/`javi-forecast` HPA를 JSON6902 `$patch: delete`로 명시적으로 제거한다. 두 오토스케일러가 같은 Deployment를 동시에 타겟팅하면 충돌하기 때문이다. 새로운 오토스케일 대상 서비스를 prod에 추가할 때 이 패턴을 빠뜨리면 운영 중 스케일링이 예측 불가능해질 수 있다.
- **Redis가 base/prod에서 의미가 다르다**: base의 단일 Redis Deployment는 dev에서만 실제로 동작한다. prod overlay는 이를 `replicas: 0`으로 비활성화하고, 대신 ArgoCD `redis-ha-app`(bitnami/redis Helm, Sentinel 3노드)을 따로 배포해 `javi-forecast`의 `REDIS_URL`을 패치로 `redis-ha-redis-master:6379`로 덮어쓴다. base 매니페스트만 보고 "Redis는 단일 Pod"라고 착각하기 쉽다.
- **GPU 노드가 없으면 Ollama가 영원히 Pending**: prod의 `ollama-gpu.yaml` 패치가 `nodeSelector: accelerator: nvidia`와 GPU toleration을 추가한다. 클러스터에 해당 레이블이 붙은 GPU 노드가 없으면 Pod이 스케줄되지 않고 대기 상태로 남는다(README에 명시).
- **`*.apm.local` / `yourdomain.com`은 placeholder**: `ingress.yaml`의 호스트명과 prod `ingress-tls.yaml`의 도메인은 실제 환경에 맞게 교체해야 동작한다. cert-manager의 HTTP-01 challenge는 `*.local` 같은 더미 도메인으로는 검증되지 않는다.
- **CLAUDE.md 자동 동기화 워크플로와의 상호작용**: 이 문서(`docs/ARCHITECTURE.md`) 자체가 `.github/workflows/sync-claudemd.yml`에 의해 PR마다 Claude Code로 자동 갱신된다. 이 봇 커밋에는 `[claude-docs]` 마커가 붙고, 워크플로는 그 마커가 있는 커밋이면 스킵해 무한 루프를 막는다. CLAUDE.md의 `<!-- AUTO-GENERATED:start/end -->` 구간은 별도 셸 스크립트(`gen-claudemd-auto.sh`)가 결정론적으로 관리하므로, 이 문서나 CLAUDE.md의 서술형 내용을 손으로 고칠 때 그 마커 구간과 혼동하지 않아야 한다.
