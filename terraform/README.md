# Terraform AWS Infrastructure – Bootstrap + Prod (S3 Remote State, EKS, ECR, OIDC, IRSA)

This repository demonstrates a production-style Terraform workflow on AWS using a **two-phase pattern**:

1. **Bootstrap** provisions the Terraform backend infrastructure (S3 remote state + state locking).
2. **Prod** provisions the actual infrastructure (VPC, EKS, ECR, GitHub Actions OIDC role, and IRSA for the EBS CSI driver) while storing its state remotely in S3.

---

## What this project demonstrates

- **Remote state** in S3 (per-environment state separation via `key`)
- **State locking** using S3 lockfile (`use_lockfile = true`)
- A clean **bootstrap pattern** (backend infra managed separately from app/prod infra)
- Secure-by-default foundations:
  - S3 public access blocked
  - S3 server-side encryption enabled
  - ECR image scanning on push + immutable tags
- **OIDC-based auth for GitHub Actions** (no long‑lived AWS credentials in CI)
- **IRSA** for Kubernetes add-ons (EBS CSI) — AWS permissions mapped to a Kubernetes ServiceAccount
- Uses well-known community modules:
  - `terraform-aws-modules/vpc/aws`
  - `terraform-aws-modules/eks/aws`
  - `terraform-aws-modules/iam/aws`

---

## Repository layout

```text
terraform/
  bootstrap/
    provider.tf            # AWS provider config (region, default_tags)
    main.tf                # S3 backend bucket (remote state)
    variables.tf           # bootstrap inputs
    terraform.tfvars       # bootstrap values
    versions.tf            # provider requirements + backend declaration (configured via backend.hcl)
    backend.hcl            # backend config for bootstrap state (local or S3 if desired)
    outputs.tf             # exported values (e.g., state bucket name)
  envs/
    prod/
      provider.tf          # AWS provider config (region, default_tags)
      main.tf              # VPC + EKS + ECR + OIDC + IRSA
      variables.tf         # prod inputs
      terraform.tfvars     # prod values
      versions.tf          # provider requirements + backend declaration (configured via backend.hcl)
      backend.hcl          # S3 backend config (bucket/key/region/encrypt/use_lockfile)
      outputs.tf           # exported values (cluster name, repo URL, role ARN, region)
```

> Terraform loads all `.tf` files in a directory as **one module** (file order does not matter).

---

## Prerequisites

- Terraform **>= 1.10.0, < 2.0.0**
- AWS credentials with permissions to create:
  - S3 bucket (bootstrap)
  - VPC, EKS, ECR, IAM, KMS (prod)
- AWS CLI (recommended for verification)
- `kubectl` (recommended for post-deploy checks)

---

## Important notes

### Remote state and “not public” S3 buckets
The state bucket is **not public**, but Terraform can still access it because it uses your AWS credentials (IAM user/role) over AWS APIs. “Not public” only blocks anonymous/public access.

### Encryption
- Backend `encrypt = true` requests **SSE-S3** (server-side encryption) for the state object.
- The bucket also enforces default server-side encryption (defense-in-depth).

### Tag mutability
ECR is configured with `IMMUTABLE`. This means a tag (including `latest`) **cannot be overwritten** once pushed.

---

## Step 1: Bootstrap (Create S3 bucket)

Run Terraform **without backend** on the first run. This creates the S3 bucket while keeping the state locally just for this initial creation step.

```bash
cd terraform/bootstrap

terraform init -backend=false
terraform fmt -check
terraform validate

terraform plan
terraform apply
```

### Key bootstrap resources
- S3 bucket for Terraform state (`aws_s3_bucket`)
- Versioning enabled (`aws_s3_bucket_versioning`)
- Server-side encryption enabled (`aws_s3_bucket_server_side_encryption_configuration`)
- Public access blocked (`aws_s3_bucket_public_access_block`)
- `prevent_destroy = true` to avoid accidental deletion of the state bucket
- Bootstrap state is local (temporary)

---

## Step 2: Migrate Bootstrap State to S3

Now initialize again using the existing `backend.hcl` and migrate the local bootstrap state into S3.

```bash
cd terraform/bootstrap

terraform init -backend-config=backend.hcl -migrate-state
terraform plan
```

### Key bootstrap resources
- Bootstrap state is stored remotely in S3

---

## Step 3: Initialize and Apply Prod Environment (Remote State)

Move to the prod environment and initialize Terraform using the existing `backend.hcl`. Then run plan/apply normally.

```bash
cd terraform/envs/prod

terraform init -backend-config=backend.hcl
terraform fmt -check
terraform validate

terraform plan -var="github_owner=YOUR_GH_OWNER" -var="github_repo=YOUR_REPO"
terraform apply -var="github_owner=YOUR_GH_OWNER" -var="github_repo=YOUR_REPO"
```

### What gets provisioned in `prod`
- **VPC** with public + private subnets and NAT Gateway
- **KMS key** for EKS secrets encryption
- **EKS cluster** (control plane + managed node group)
- **EBS CSI driver** as a managed EKS add-on, using **IRSA**
- **ECR repository** with scanning on push, immutable tags, and lifecycle cleanup (keep last 50 images)
- **IAM OIDC provider** for GitHub Actions + IAM role with least-privilege permissions
- **EKS access entry** granting the GitHub Actions role cluster admin access (for deployment)

---

## GitHub Actions OIDC (no static AWS keys)

This repo configures an IAM OIDC provider for GitHub Actions and a deployer IAM role.

High-level flow:
1. GitHub Actions requests an OIDC token from GitHub.
2. AWS STS validates the token against the configured OIDC provider.
3. STS returns **temporary credentials** for the deployer role.
4. The workflow pushes to ECR and deploys to EKS (as permitted by the attached IAM policy).

The trust policy restricts access using:
- `aud` == `sts.amazonaws.com`
- `sub` matches the repository and GitHub Environment (recommended for prod deployments)

---

## IRSA for the EBS CSI driver (why it matters)

The EBS CSI controller needs AWS permissions to create/attach EBS volumes for PVCs.
With **IRSA**, those AWS permissions are granted to a Kubernetes **ServiceAccount** (not stored as access keys).

This repo:
- Creates an IAM role trusted via the EKS OIDC provider
- Restricts it to `kube-system:ebs-csi-controller-sa`
- Configures the `aws-ebs-csi-driver` add-on to use that role

---

## Outputs

After `terraform apply` in prod, useful outputs include:
- `cluster_name`
- `region`
- `ecr_repository_url`
- `gha_role_arn`

To view:
```bash
terraform output
```

---

## Verification

### Confirm EKS access
```bash
aws eks update-kubeconfig --region eu-west-2 --name <cluster_name>
kubectl get nodes
```

### Confirm EBS CSI driver is installed and uses IRSA
```bash
kubectl -n kube-system get pods | grep ebs-csi
kubectl -n kube-system get sa ebs-csi-controller-sa -o yaml
```

### Confirm ECR repository exists
```bash
aws ecr describe-repositories --repository-names counter-service --region eu-west-2
```

---

## Troubleshooting

### `Bucket does not exist` during `terraform init`
- Ensure you ran **bootstrap apply** successfully.
- Confirm the bucket name in `backend.hcl` matches the created bucket.

### State lock errors
- Another Terraform operation may be running.
- If using lockfiles, check the lock object in S3 (only force-unlock if you are sure no apply is running).

### `AccessDenied`
- Verify the IAM principal you use locally/CI has permissions for:
  - state bucket read/write
  - creating/updating the AWS resources in prod

### EKS API access from CI fails
- Ensure the GitHub role has `eks:DescribeCluster` permissions.
- Ensure EKS `access_entries` (cluster access) is configured for that role.

---

## Cleanup

> **Warning:** never delete the Terraform state bucket unless you fully understand the impact.

To destroy prod infrastructure:
```bash
cd terraform/envs/prod
terraform destroy
```

Bootstrap (state bucket) is protected with `prevent_destroy = true` by design.
If you truly must delete it, remove that lifecycle rule intentionally and re-run apply/destroy (not recommended for normal workflows).

---

## Notes for reviewers

This project is intentionally structured to resemble real-world IaC practices:
- safe state handling
- clear separation between Terraform backend (bootstrap) and production infrastructure (prod)
- security-first defaults
- CI-friendly auth (OIDC) and K8s-to-AWS auth (IRSA)

