# javi-infra

Kubernetes manifests for the Javi APM platform.

All application source repos (javi-collector, javi-forecast, javi-dashboard) contain only source code and Dockerfiles. This repo is the single source of truth for cluster state.

## Structure

```
javi-infra/
├── argocd/
│   ├── namespace.yaml           # argocd 네임스페이스
│   └── apps/
│       ├── apm-prod-app.yaml    # prod 자동 배포 (auto-sync)
│       ├── apm-dev-app.yaml     # dev 수동 배포
│       ├── monitoring-app.yaml  # kube-prometheus-stack
│       ├── redis-ha-app.yaml    # bitnami/redis Sentinel (prod HA)
│       └── keda-app.yaml        # KEDA operator (Kafka lag 스케일링)
├── cert-manager/
│   └── cluster-issuer.yaml      # Let's Encrypt staging + prod ClusterIssuer
└── k8s/
    ├── base/                    # Environment-agnostic manifests
    │   ├── namespace.yaml
    │   ├── ingress.yaml
    │   ├── resource-quota.yaml      # namespace CPU/Memory 예산
    │   ├── kustomization.yaml
    │   ├── rbac/
    │   │   └── service-accounts.yaml  # 서비스별 전용 ServiceAccount
    │   ├── clickhouse/
    │   │   ├── backup-pvc.yaml      # 백업용 PVC (20Gi)
    │   │   └── backup-cronjob.yaml  # 매일 02:00 자동 백업
    │   ├── collector/
    │   ├── config-server/
    │   ├── dashboard/
    │   ├── forecast/
    │   ├── kafka/
    │   ├── ollama/
    │   ├── qdrant/
    │   └── redis/
    └── overlays/
        ├── dev/                 # Single replica, ephemeral storage, reduced resources
        │   ├── kustomization.yaml  # CPU HPA included (no KEDA)
        │   └── patches/
        └── prod/                # 3-replica Kafka, persistent storage, scaled resources
            ├── kustomization.yaml
            ├── scaledobject-forecast.yaml  # KEDA Kafka lag ScaledObject
            └── patches/
                ├── ingress-tls.yaml   # HTTPS + cert-manager
                └── ollama-gpu.yaml    # GPU nodeSelector + tolerations
```

## Services

| Service | Description |
|---------|-------------|
| javi-collector | OTLP trace/metric/log ingest |
| javi-forecast | AIOps anomaly detection & forecasting |
| javi-dashboard | Web UI + API backend |
| javi-config-server | Agent remote config polling |
| kafka | Strimzi-managed Kafka cluster |
| clickhouse | Time-series storage |
| qdrant | Vector DB for RAG |
| ollama | Local LLM inference |
| redis | Feature store shared across forecast replicas |

## Deploy

```bash
# Dev
kubectl apply -k k8s/overlays/dev

# Prod
kubectl apply -k k8s/overlays/prod
```

> **Prerequisites**
> - Strimzi operator: `kubectl create -f 'https://strimzi.io/install/latest?namespace=apm'`
> - nginx ingress controller installed

## Image Tags

CI pipelines inject `IMAGE_TAG` at build time. Base manifests use `latest` as a placeholder — never deploy base directly; always go through an overlay.

---

## GitOps — ArgoCD

```bash
# 1. ArgoCD 설치 (최초 1회)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. ArgoCD 네임스페이스 + Application 등록
kubectl apply -f argocd/namespace.yaml
kubectl apply -f argocd/apps/

# 3. ArgoCD UI 접속 (초기 비밀번호 확인)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

이후 `git push main` 하면 `apm-prod` Application이 자동으로 클러스터에 sync됩니다.

## TLS — cert-manager

```bash
# 1. cert-manager 설치
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# 2. cert-manager Pod가 Running 상태가 된 후 ClusterIssuer 생성
kubectl apply -f cert-manager/cluster-issuer.yaml

# 3. k8s/overlays/prod/patches/ingress-tls.yaml에서 yourdomain.com을 실제 도메인으로 교체
# 4. DNS A 레코드: *.apm.yourdomain.com → nginx Ingress LoadBalancer IP

# 검증
kubectl describe clusterissuer letsencrypt-staging
kubectl describe certificate -n apm
```

## Monitoring — Prometheus + Grafana

```bash
# ArgoCD가 없으면 Helm으로 직접 설치
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f <(kubectl get -f argocd/apps/monitoring-app.yaml -o jsonpath='{.spec.source.helm.valuesObject}')

# Grafana admin secret 생성 (ArgoCD 배포 전 필요)
kubectl create secret generic grafana-admin-secret -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)"
```

## RBAC — ServiceAccount 분리

각 서비스는 전용 ServiceAccount를 가지며 `automountServiceAccountToken: false`로 K8s API 접근을 차단합니다.

| ServiceAccount | 대상 워크로드 |
|---------------|--------------|
| javi-collector | Collector Deployment |
| javi-forecast | Forecast Deployment |
| javi-dashboard | Dashboard Deployment |
| javi-config-server | Config Server Deployment |
| ollama | Ollama Deployment |
| qdrant | Qdrant StatefulSet |
| clickhouse | ClickHouse StatefulSet |
| clickhouse-backup | Backup CronJob |
| redis | Redis Deployment (base/dev) |

## Redis HA — Sentinel

Prod에서는 base의 단일 Redis(replicas=0으로 비활성화)를 대신해 bitnami/redis Sentinel 3노드를 사용합니다.

```bash
# 1. ArgoCD가 redis-ha-app을 자동 배포
kubectl apply -f argocd/apps/redis-ha-app.yaml

# 상태 확인
kubectl get pods -n apm -l app.kubernetes.io/name=redis

# 마스터 확인
kubectl exec -n apm redis-ha-redis-node-0 -c redis -- redis-cli info replication | grep role
```

- 마스터 서비스: `redis-ha-redis-master:6379` (forecast REDIS_URL로 자동 설정됨)
- Sentinel 포트: 26379 (quorum 2/3)
- 장애 발생 시 Sentinel이 자동으로 새 마스터 승격

## KEDA — Kafka Lag 기반 스케일링

Prod에서 `javi-forecast`는 CPU 기반 HPA 대신 Kafka consumer lag으로 스케일링됩니다.

```bash
# 1. KEDA operator 설치 (ArgoCD가 keda-app으로 자동 배포)
kubectl apply -f argocd/apps/keda-app.yaml

# ScaledObject 상태 확인
kubectl get scaledobject -n apm
kubectl describe scaledobject javi-forecast -n apm

# 현재 lag 확인
kubectl get hpa -n apm  # KEDA가 내부적으로 생성하는 HPA
```

- Kafka topic: `spans.all`, consumer group: `javi-forecast`
- lagThreshold: 100 (lag이 100 이상이면 Pod 추가)
- minReplicas: 2, maxReplicas: 8
- Dev 환경: KEDA 없이 CPU 기반 HPA 사용 (`k8s/base/forecast/hpa.yaml`)

## Ollama — GPU 노드 분리

Prod에서 Ollama Pod는 GPU 노드에만 스케줄됩니다.

```bash
# GPU 노드에 레이블 부여 (최초 1회)
kubectl label node <gpu-node-name> accelerator=nvidia

# 확인
kubectl get node --show-labels | grep accelerator
kubectl get pod -n apm -l app=ollama -o wide
```

- `nodeSelector: accelerator: nvidia`
- `tolerations: nvidia.com/gpu: NoSchedule`
- GPU 리소스: `nvidia.com/gpu: 1` (NVIDIA device plugin 필요)
- GPU 노드가 없으면 Pod가 Pending 상태로 대기

## ResourceQuota

`apm` 네임스페이스 전체에 리소스 예산을 설정합니다.

| 항목 | 제한 |
|------|------|
| requests.cpu | 8 코어 |
| requests.memory | 24Gi |
| limits.cpu | 20 코어 |
| limits.memory | 48Gi |
| pods | 60 |
| services / PVC / secret / configmap | 20 / 20 / 40 / 40 |

```bash
# 현재 사용량 확인
kubectl describe resourcequota apm-quota -n apm
```

## ClickHouse 백업

백업은 매일 UTC 17:00 (KST 02:00) 자동 실행되며 `/backups/` PVC에 저장됩니다. 최근 7개 유지.

```bash
# 백업 즉시 실행 (테스트)
kubectl create job -n apm clickhouse-backup-manual \
  --from=cronjob/clickhouse-backup

# 백업 목록 확인
kubectl exec -n apm -it $(kubectl get pod -n apm -l app=clickhouse-backup -o name | head -1) \
  -- ls -lh /backups/

# 복구 (특정 테이블)
# 1. 백업 Pod 접속 또는 PVC를 다른 Pod에 마운트
# 2. gunzip < /backups/<date>/<table>.native.gz | \
#      clickhouse-client -h clickhouse-svc --query "INSERT INTO apm.<table> FORMAT Native"
```
