# javi-infra

Kubernetes manifests for the Javi APM platform.

All application source repos (javi-collector, javi-forecast, javi-dashboard) contain only source code and Dockerfiles. This repo is the single source of truth for cluster state.

## Structure

```
k8s/
├── base/                    # Environment-agnostic manifests
│   ├── namespace.yaml
│   ├── ingress.yaml
│   ├── kustomization.yaml
│   ├── clickhouse/
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
    │   ├── kustomization.yaml
    │   └── patches/
    └── prod/                # 3-replica Kafka, persistent storage, scaled resources
        ├── kustomization.yaml
        └── patches/
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
