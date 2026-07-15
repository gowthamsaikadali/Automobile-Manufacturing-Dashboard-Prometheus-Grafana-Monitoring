# AutoForge — Automobile Manufacturing Dashboard on AWS EKS

Two-tier Flask + MySQL RDS app, deployed to EKS with Terraform + Helm,
CI/CD via GitHub Actions (SonarQube + Trivy), and full observability
(Prometheus, Grafana, Loki, CloudWatch alarms). No custom domain — you
access the app via the ALB's own DNS name. No AWS account ID is hardcoded
anywhere in the repo; it's passed in via `terraform.tfvars` (gitignored)
and GitHub Secrets.

All commands below are **Windows PowerShell**. Run them one block at a time
and read the comment above each block before running it.

---

## 0. Prerequisites (one-time, on your machine)

```powershell
# Check these are installed - install any that are missing
aws --version
terraform -version
kubectl version --client
helm version
docker --version
git --version
python --version
```

Configure your AWS CLI with a real IAM user that has admin rights for this
build-out (you'll lock things down with least-privilege roles afterward):

```powershell
aws configure
# AWS Access Key ID, Secret Access Key, region = ap-south-1, output = json
```

---

## 1. Create the GitHub repo and push this project

```powershell
cd C:\Users\<you>\Projects
# (copy/extract the autoforge folder here first)
cd autoforge
git init
git add .
git commit -m "Initial commit: AutoForge from scratch"
git branch -M main
git remote add origin https://github.com/gowthamsaikadali/Automobile-Manufacturing-Dashboard-Prometheus-Grafana-Monitoring.git
git push -u origin main
```

---

## 2. Bootstrap Terraform remote state (S3 + DynamoDB)

Pick a **globally unique** S3 bucket name (e.g. add your name/date):

```powershell
cd terraform\bootstrap
terraform init
terraform apply -var="state_bucket_name=autoforge-tfstate-gowtham-2026"
```

Copy the bucket name into `terraform\environments\dev\backend.tf` (replace
the placeholder on the `bucket = ` line).

---

## 3. Fill in your real values

```powershell
cd ..\environments\dev
copy terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars
```

Fill in: your AWS account ID, a strong `db_password`, and your real email
for `alarm_email` (you'll get an SNS confirmation email you must click).
**Never commit this file** — it's already gitignored.

---

## 4. Phase 1 apply — network, EKS, RDS, ECR, IAM

```powershell
terraform init
terraform apply `
  -target=module.vpc `
  -target=module.eks `
  -target=module.ecr `
  -target=module.rds `
  -target=module.iam
```

This takes ~15 minutes (EKS control plane is the slow part). When done:

```powershell
terraform output
```

Note down `eks_cluster_name`, `ecr_repository_url`, `rds_endpoint`,
`github_deploy_role_arn`, `external_secrets_role_arn`.

---

## 5. Point kubectl at the new cluster

```powershell
aws eks update-kubeconfig --name autoforge-eks --region ap-south-1
kubectl get nodes
```

You should see 2 `t3.small` nodes in `Ready` state.

---

## 6. Install cluster add-ons (ALB Controller + External Secrets Operator)

```powershell
# AWS Load Balancer Controller (creates the ALB from our Ingress resource)
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller `
  -n kube-system `
  --set clusterName=autoforge-eks `
  --set serviceAccount.create=true `
  --set region=ap-south-1 `
  --set vpcId=<PASTE vpc_id FROM terraform output>

# External Secrets Operator (pulls DB creds from Secrets Manager into K8s Secrets)
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets `
  -n external-secrets-system --create-namespace
```

> Note: the AWS Load Balancer Controller also needs an IAM policy + IRSA role
> attached to its service account. If `helm install` above doesn't attach
> permissions automatically in your chart version, follow the official
> "IAM policy for the AWS Load Balancer Controller" doc and attach that
> policy's ARN to the `aws-load-balancer-controller` service account via
> `eks.amazonaws.com/role-arn` annotation, then restart the pod.

---

## 7. Create the secret in AWS Secrets Manager (read by External Secrets Operator)

```powershell
aws secretsmanager create-secret `
  --name autoforge/db-credentials `
  --secret-string '{\"password\":\"<same db_password from tfvars>\",\"flask_secret_key\":\"<generate a random 32+ char string>\",\"admin_password\":\"<password you want for the admin login>\"}' `
  --region ap-south-1
```

Generate a random Flask secret key quickly:

```powershell
python -c "import secrets; print(secrets.token_hex(32))"
```

---

## 8. Seed the database (schema + admin user)

Run this from your machine — it needs network access to the RDS endpoint,
so run it from a machine/bastion inside the VPC, or temporarily allow your
IP in the RDS security group, or run it as a one-off Kubernetes Job using
the same image. Simplest for a fresh setup: run it as a K8s Job.

```powershell
kubectl create namespace autoforge

kubectl run autoforge-seed --rm -i --restart=Never `
  --image=python:3.12-slim -n autoforge -- bash -c "
    pip install pymysql bcrypt --quiet &&
    python -c \"
import os
DB_HOST='<rds_endpoint from terraform output>'
\" "
```

Easier in practice: copy `app/seed.py` and `app/requirements.txt` into the
cluster via a quick Job, or just run `seed.py` locally with these env vars
set (works if your IP is temporarily allowed into the RDS security group):

```powershell
$env:DB_HOST="<rds_endpoint>"
$env:DB_USER="autoforge_admin"
$env:DB_PASSWORD="<db_password>"
$env:DB_NAME="autoforge"
$env:ADMIN_USERNAME="admin"
$env:ADMIN_PASSWORD="<admin_password you used in secrets manager>"
cd ..\..\..\app
pip install -r requirements.txt --quiet
python seed.py
```

---

## 9. Build and push the first image manually (before CI/CD exists yet)

```powershell
cd ..\app
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin <ecr_repository_url minus the repo name>
docker build -t autoforge-app .
docker tag autoforge-app:latest <ecr_repository_url>:latest
docker push <ecr_repository_url>:latest
```

---

## 10. Deploy the app with Helm (Phase 1 — before WAF/monitoring wiring)

```powershell
cd ..\helm\autoforge
helm upgrade --install autoforge . `
  --namespace autoforge --create-namespace `
  --set image.repository=<ecr_repository_url> `
  --set image.tag=latest `
  --set db.host=<rds_endpoint> `
  --set externalSecrets.irsaRoleArn=<external_secrets_role_arn>

kubectl get pods -n autoforge
kubectl get ingress -n autoforge
```

Wait 2-3 minutes for the ALB to provision, then grab its DNS name:

```powershell
kubectl get ingress autoforge-app-ingress -n autoforge -o jsonpath="{.status.loadBalancer.ingress[0].hostname}"
```

Open that hostname + `/login` in your browser — you should see the Admin
Login screen. Sign in with the admin username/password you seeded.

---

## 11. Phase 2 Terraform apply — WAFv2 + CloudWatch alarms

Now that the ALB exists (named `autoforge-alb` per the ingress annotation),
finish the rest of the infra:

```powershell
cd ..\..\terraform\environments\dev
terraform apply
```

This attaches the WAFv2 WebACL to your ALB and wires up CloudWatch alarms
for RDS CPU/storage/connections and ALB 5xx/latency. Check your email and
confirm the SNS subscription so alarm emails actually arrive.

---

## 12. Monitoring stack — Prometheus, Grafana, Loki

```powershell
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack `
  -n monitoring --create-namespace -f ..\..\..\monitoring\prometheus-values.yaml

helm install loki grafana/loki-stack `
  -n monitoring -f ..\..\..\monitoring\loki-values.yaml

kubectl apply -f ..\..\..\monitoring\servicemonitor-and-rules.yaml
```

Import the dashboard: open Grafana (see below), go to **Dashboards → Import**,
and paste the contents of `monitoring/grafana-dashboards/autoforge-overview.json`.

Access Grafana:

```powershell
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
# browse to http://localhost:3000  (user: admin / password from prometheus-values.yaml)
```

Add Loki as a datasource in Grafana: **Connections → Data sources → Add
data source → Loki**, URL = `http://loki.monitoring.svc.cluster.local:3100`.

---

## 13. Wire up GitHub Actions CI/CD

In your GitHub repo → **Settings → Secrets and variables → Actions**, add:

| Secret | Value |
|---|---|
| `AWS_GITHUB_DEPLOY_ROLE_ARN` | `github_deploy_role_arn` from terraform output |
| `ECR_REGISTRY` | the registry part of `ecr_repository_url` (before the repo name) |
| `RDS_ENDPOINT` | `rds_endpoint` from terraform output |
| `EXTERNAL_SECRETS_ROLE_ARN` | `external_secrets_role_arn` from terraform output |
| `SONAR_TOKEN` | token from your SonarQube instance |
| `SONAR_HOST_URL` | your SonarQube server URL |

From now on, every push to `main` that touches `app/**` or `helm/**` will:
SonarQube scan → build image → Trivy scan (fails the build on HIGH/CRITICAL
vulns) → push to ECR → `helm upgrade` to EKS → verify rollout.

---

## 14. Test alerting (deliberately break something)

**Kill a pod and watch it recover / alert:**
```powershell
kubectl delete pod -n autoforge -l app=autoforge-app --force
kubectl get pods -n autoforge -w
```
Watch the `AutoForgePodCrashLooping` / `AutoForgeNoPodsReady` rules in
Prometheus (**Alerts** tab) and confirm a Slack/CloudWatch notification.

**Spike CPU on a node (to test the CloudWatch CPU>80% alarm):**
```powershell
kubectl run cpu-stress --image=progrium/stress -n autoforge -- --cpu 4 --timeout 300s
```
Watch the alarm go into `ALARM` state in the CloudWatch console within a
few minutes, and confirm you get the SNS email.

**Force a 5xx to test ALB error-rate alarm:** temporarily scale the
deployment to 0 replicas for a minute (ALB will return 503s to health
checks), then scale back up:
```powershell
kubectl scale deployment autoforge-app -n autoforge --replicas=0
Start-Sleep -Seconds 90
kubectl scale deployment autoforge-app -n autoforge --replicas=2
```

---

## Repo layout

```
app/                  Flask app, templates, static CSS, Dockerfile, seed.py
terraform/
  bootstrap/          S3 + DynamoDB remote state (run once)
  modules/            vpc, eks, rds, ecr, iam, waf, monitoring
  environments/dev/   wires all modules together for this environment
helm/autoforge/       Helm chart: Deployment, Service, Ingress(ALB), HPA,
                       ServiceAccount, ExternalSecret/SecretStore
monitoring/           kube-prometheus-stack values, Loki values,
                       ServiceMonitor + PrometheusRule, Grafana dashboard JSON
.github/workflows/     CI/CD: SonarQube -> Trivy -> ECR push -> Helm deploy
```

## Cost notes
- No NAT Gateway by default (nodes run in public subnets with security
  groups locking down inbound access) — saves ~$32/month. Flip
  `enable_nat = true` in the vpc module if you need private subnets later.
- `db.t3.micro` RDS + 2x `t3.small` EKS nodes keeps this within/near
  free-tier-adjacent cost for a dev environment.
- Remember to `terraform destroy` (and `helm uninstall` everything) when
  you're done demoing, to avoid ongoing charges.
