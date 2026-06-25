# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트

Javi APM 플랫폼의 Kubernetes GitOps 인프라 레포. 소스 코드 없음, 매니페스트만. `git push main` → ArgoCD auto-sync → 클러스터 반영.

## 실행 환경

```bash
# 배포
kubectl apply -k k8s/overlays/dev    # 개발
kubectl apply -k k8s/overlays/prod   # 운영

# 검증 (dry-run)
kubectl kustomize k8s/overlays/prod | kubectl apply --dry-run=client -f -

# prod secrets 교체
./scripts/seal-secrets.sh  # kubeseal CLI + sealed-secrets controller 필요
```

## 하지 말아야 할 일

- `k8s/base/` 직접 배포 금지 — 반드시 overlay(`dev` or `prod`) 경유
- `k8s/overlays/dev/secrets/` 에 실제 자격증명 커밋 금지 — placeholder 전용
- `kubectl` 직접 수정 금지 — ArgoCD `selfHeal: true`가 자동으로 되돌림
- prod 이미지 태그 수동 수정 금지 — CI(`build-push.yml`)가 `kustomization.yaml`에 자동 커밋
- 새 서비스 추가 시 NetworkPolicy allow 규칙 없이 배포 금지 — 기본 deny-all 정책

<!-- AUTO-GENERATED:start (스크립트가 관리. 직접 수정 금지) -->

_아래 구간은 스크립트가 자동 생성합니다. 직접 수정하지 마세요._

### 기술 스택
- (자동 감지된 매니페스트 없음)

### 명령어

### 최상위 디렉터리 구조
```
.github
argocd
cert-manager
k8s
scripts
```

<!-- AUTO-GENERATED:end -->
