# Counter Service on AWS EKS (Terraform + Helm + GitHub Actions)

This repository implements a lightweight Python-based **counter service** that increments on **POST** requests and returns the current count on **GET** requests.

It is containerized with Docker, deployed to **Amazon EKS** (region **eu-west-2**) using **Helm**, and delivered via a fully automated **GitHub Actions** CI/CD pipeline using **OIDC** (no long‑lived AWS credentials in CI).

---

## Prerequisites

Local tools:
- **AWS CLI** (for provisioning/verification and kubeconfig)
- **Terraform** `>= 1.10, < 2.0`
- **kubectl**
- **Helm**
- **Docker**

---

## Credentials and secrets (safe setup)

### Local development (your machine)
Configure AWS CLI using your IAM user (or a role you can assume):

```bash
aws configure
aws sts get-caller-identity
```

> Do **not** commit any credentials to Git.

### CI/CD (GitHub Actions)
CI/CD uses **GitHub OIDC → AWS STS AssumeRoleWithWebIdentity**, which provides **temporary credentials** at runtime. No static AWS keys are stored in GitHub.

Recommended GitHub repository settings:
- Use a **GitHub Environment** named `prod` with optional manual approvals (for CD gating).
- Store non-secret configuration as **Actions Variables** (cluster name, release name, etc.).
- If you ever need secrets (e.g., AWS_ROLE_ARN), store them as **Actions Secrets**.

---

## Provision the cluster (high level)

Infrastructure is provisioned using a **two-phase Terraform pattern**:
1. **bootstrap**: creates the Terraform backend (S3 remote state + locking)
2. **prod**: creates VPC + EKS + ECR + OIDC/IRSA (including EBS CSI driver)

For the full details and exact steps, see: `infra/terraform/README.md`.

### Required EKS setting (important)
The EKS cluster must use **Upgrade Policy: STANDARD** (not EXTENDED).

Verify:
```bash
aws eks describe-cluster --region <AWS_REGION> --name <CLUSTER_NAME> --query "cluster.upgradePolicy" --output json
```

### Post-provision step: encrypted StorageClass (required for PVCs)
After the cluster is up and reachable, apply the encrypted gp3 StorageClass:

```bash
kubectl apply -f infra/k8s/storageclass_gp3_encrypted.yaml
kubectl get storageclass
```

---

## Verification checklist (before running CI/CD)

These are the key checks used while bringing the cluster up:

```bash
# cluster readiness + required policy
aws eks describe-cluster --region <AWS_REGION> --name <CLUSTER_NAME> --query "cluster.status" --output text
aws eks describe-cluster --region <AWS_REGION> --name <CLUSTER_NAME> --query "cluster.upgradePolicy" --output json

# add-ons
aws eks list-addons --cluster-name <CLUSTER_NAME> --output table

# kube access
aws eks update-kubeconfig --region <AWS_REGION> --name <CLUSTER_NAME>
kubectl get nodes
kubectl get pods -n kube-system

# EBS CSI / IRSA
kubectl get sa -n kube-system | grep -i ebs
kubectl get sa -n kube-system ebs-csi-controller-sa -o jsonpath="{.metadata.annotations.eks\.amazonaws\.com/role-arn}"

# encrypted StorageClass for dynamic EBS provisioning
kubectl get storageclass
```

---

## CI/CD pipeline

Workflows live under `.github/workflows/`:
- **CI** (`ci.yml`): lint/tests + Docker build + image scan
- **CD** (`cd.yml`): on push to `main`, builds & pushes image to **ECR**, then deploys to EKS using **Helm**

### How to run the pipeline
- Open a PR → CI runs automatically.
- Merge/push to `main` → CD runs automatically and upgrades the live service in the `prod` namespace.

---

## Deployment (manual)

The automated CD runs the equivalent of the following Helm command (example):

```bash
ECR="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/counter-service"
TAG="1.0.1"

helm upgrade --install counter-service helm_charts/counter-service --create-namespace -n prod --set image.repository=${ECR} --set image.tag=${TAG} --set env.APP_VERSION=${TAG} -f helm_charts/counter-service/values-prod.yaml
```

---

## How to deploy and test

### Get the external endpoint
```bash
kubectl get svc -n prod
```

For a `LoadBalancer` Service, use the EXTERNAL-IP/hostname to form the base URL:
```bash
BASE_URL="http://<external-hostname>"
```

### API checks
```bash
# current counter
curl "$BASE_URL/"

# increment
curl -X POST "$BASE_URL/"

# health (used by readiness/liveness probes)
curl "$BASE_URL/healthz"

# version (used to prove CD updates)
curl "$BASE_URL/version"
```

### Persistence check (counter survives restarts)
```bash
# increment a few times
curl -X POST "$BASE_URL/"
curl -X POST "$BASE_URL/"

# restart the Deployment
kubectl rollout restart deploy/counter-service -n prod
kubectl rollout status deploy/counter-service -n prod

# verify counter is preserved
curl "$BASE_URL/"
```

---

## Notes on HA, scaling, persistence choices, and trade-offs

### Persistence model
The counter is stored in a JSON file (default `/data/counter.json`) on a PVC.
To prevent corrupted writes, the application uses an **exclusive file lock** and an **atomic write** pattern (write temp → replace).

### Why replicas = 1
This deployment uses **EBS CSI** volumes, which are typically **ReadWriteOnce (RWO)**. That means the volume can be attached read-write to **one node at a time**, which strongly implies running a **single replica** when persisting state to a shared file.

### How to scale horizontally (without changing app code)
Two practical options:
- **EFS CSI (RWX)**: shared filesystem across nodes; multiple pods can mount `/data` concurrently.
- **External state store**: DynamoDB/Redis/RDS (atomic operations / transactions) for a proper distributed counter.

### Metrics and concurrency (quick note)
- With **multiple pods**, Prometheus scraping and aggregation is straightforward.
- With **multiple worker processes** inside a single pod (Gunicorn `workers>1`), Prometheus multiprocess metrics typically require extra setup.

---

## Observability & security (baseline)

- **Probes**: `/healthz` readiness/liveness endpoints for stable rollouts.
- **Version endpoint**: `/version` returns the build tag/commit SHA to prove CD updates.
- **Container security**: runs as **non-root** and uses **readOnlyRootFilesystem** (with `/data` mounted from a PVC).
- **Resource requests/limits**: defined in the Helm values.
- **Image scanning**: ECR scanning on push + CI image scan (Trivy).
- **Encryption**:
  - Terraform remote state stored in S3 with encryption enabled
  - EKS secrets encryption (KMS) and encrypted storage via StorageClass

---

## Rollback strategy

Helm keeps release history, so rollbacks are straightforward:

```bash
helm history counter-service -n prod
helm rollback counter-service <REVISION> -n prod
```

---

## Evidence for submission

Place screenshots and/or captured CLI outputs under `evidence/`, for example:
- CI build + scan success
- CD deployment on push to `main`
- `kubectl get deploy,po,svc,pvc -n prod`
- Service responding correctly (GET/POST + counter) and `/version` updated after a commit

---

## Additional documentation

- Terraform deep dive: `infra/terraform/README.md`
- Application notes: `app/README.md`
- Extended design notes / trade-offs: `docs/design-notes.md`
