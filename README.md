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

Fill in: your AWS account ID, and a strong `db_password`.
**Never commit this file** — it's already gitignored.

---

## 4. Apply Terraform — network, EKS, RDS, ECR, IAM

This root module (`terraform/environments/dev`) only contains infrastructure
that does **not** depend on the ALB existing yet, so a plain `terraform
apply` is always safe here — no `-target` flags needed, and nothing here
will ever try to look up a load balancer that doesn't exist yet.

```powershell
terraform init
terraform apply
```

Type `yes` when prompted. This takes ~15 minutes (the EKS control plane is
the slow part). When done:

```powershell
terraform output
```

Note down `eks_cluster_name`, `ecr_repository_url`, `rds_endpoint`,
`github_deploy_role_arn`, `external_secrets_role_arn`.

> **A note on copy-pasting commands from a chat window into PowerShell:**
> long commands can sometimes pick up a stray space or line break from how
> the browser wraps text, which breaks flags like `-target=module.vpc` in
> hard-to-spot ways. If a command errors in a way that doesn't make sense
> for what you typed, try typing it manually instead of pasting, or save it
> to a `.ps1` file and run that.

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

First generate a random Flask secret key:

```powershell
python -c "import secrets; print(secrets.token_hex(32))"
```

Copy that output, then run (in PowerShell, single-quoted strings don't need
the inner double quotes escaped — no backslashes):

```powershell
aws secretsmanager create-secret `
  --name autoforge/db-credentials `
  --secret-string '{"password":"<same db_password from tfvars>","flask_secret_key":"<paste the generated key>","admin_password":"<password you want for the dashboard login>"}' `
  --region ap-south-1
```

Verify it saved correctly (should print the same JSON back, no stray `\`):

```powershell
aws secretsmanager get-secret-value --secret-id autoforge/db-credentials --region ap-south-1 --query SecretString --output text
```

---

## 8. Build and push the first image manually (before CI/CD exists yet)

```powershell
cd ..\..\..\app
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin <ecr_repository_url minus the repo name>
docker build -t autoforge-app .
docker tag autoforge-app:latest <ecr_repository_url>:latest
docker push <ecr_repository_url>:latest
```

`<ecr_repository_url minus the repo name>` means just the registry host —
e.g. if `ecr_repository_url` is `762131619075.dkr.ecr.ap-south-1.amazonaws.com/autoforge-app`,
use `762131619075.dkr.ecr.ap-south-1.amazonaws.com` for the login command.

---

## 9. Seed the database (schema + admin user)

RDS sits in a private subnet and its security group only allows traffic
from the EKS cluster — **not from your laptop**, no matter what you allow
manually. So this has to run as a pod inside the cluster, using the image
you just pushed in Step 8 (it already has `seed.py`, `pymysql`, and
`bcrypt` baked in).

```powershell
kubectl create namespace autoforge

kubectl run autoforge-seed `
  --rm -i --restart=Never `
  --image=<ecr_repository_url>:latest `
  -n autoforge `
  --env="DB_HOST=<rds_endpoint from terraform output>" `
  --env="DB_USER=autoforge_admin" `
  --env="DB_PASSWORD=<db_password from tfvars>" `
  --env="DB_NAME=autoforge" `
  --env="ADMIN_USERNAME=admin" `
  --env="ADMIN_PASSWORD=<the admin_password you set in Step 7's secret>" `
  --command -- python seed.py
```

You should see: `Seed complete. Admin user 'admin' is ready.` If the pod
hangs or errors on connection, double check `DB_HOST` matches
`terraform output` exactly and that the EKS node group finished creating
before RDS was ready (rare timing issue — just re-run if so).

---

## 10. Deploy the app with Helm

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

This lives in a **separate Terraform root** (`terraform/environments/dev-phase2`)
with its own state file, specifically so it's impossible to accidentally run
it before the ALB exists. Only do this step once `kubectl get ingress` (end
of Step 10) actually shows a hostname.

```powershell
cd ..\..\dev-phase2
copy terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars
```

Fill in your real email for `alarm_email` (you'll get an SNS confirmation
email you must click) and the same `phase1_state_bucket` name you used in
Step 2. Then edit `backend.tf` in this same folder and replace the bucket
placeholder, same as you did in Step 2.

```powershell
terraform init
terraform apply
```

This looks up your ALB by name (`autoforge-alb`), attaches the WAFv2 WebACL
to it, and wires up CloudWatch alarms for RDS CPU/storage/connections and
ALB 5xx/latency — pulling the EKS cluster name automatically from phase 1's
state file, so there's nothing to copy/paste by hand. Confirm the SNS
subscription email so alarm notifications actually arrive.

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
app/                       Flask app, templates, static CSS, Dockerfile, seed.py
terraform/
  bootstrap/                S3 + DynamoDB remote state (run once)
  modules/                  vpc, eks, rds, ecr, iam, waf, monitoring
  environments/dev/         Phase 1: vpc, eks, ecr, rds, iam - no ALB dependency,
                             always safe to `terraform apply` directly
  environments/dev-phase2/  Phase 2: waf, monitoring - separate state file,
                             reads phase 1's outputs via terraform_remote_state.
                             Only apply this AFTER the ALB exists.
helm/autoforge/            Helm chart: Deployment, Service, Ingress(ALB), HPA,
                             ServiceAccount, ExternalSecret/SecretStore
monitoring/                 kube-prometheus-stack values, Loki values,
                             ServiceMonitor + PrometheusRule, Grafana dashboard JSON
.github/workflows/          CI/CD: SonarQube -> Trivy -> ECR push -> Helm deploy
```

## Cost notes
- No NAT Gateway by default (nodes run in public subnets with security
  groups locking down inbound access) — saves ~$32/month. Flip
  `enable_nat = true` in the vpc module if you need private subnets later.
- `db.t3.micro` RDS + 2x `t3.small` EKS nodes keeps this within/near
  free-tier-adjacent cost for a dev environment.
- Remember to `terraform destroy` (and `helm uninstall` everything) when
  you're done demoing, to avoid ongoing charges.
