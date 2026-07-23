# Automobile Manufacturing Dashboard — Full Deployment Guide

This is a truly clean, from-scratch build — starting from an **empty AWS
account**. It provisions everything: VPC, EKS cluster, RDS, ECR, the AWS
Load Balancer Controller, then the Flask app (app tier) + MySQL RDS
(data tier), then the full monitoring stack. **No domain name needed**
anywhere — you use the ALB's auto-generated DNS name, exactly like your
screenshot.

Prerequisites on your machine: AWS CLI configured (`aws configure`) with
an IAM user/role that has admin-ish permissions, Terraform >= 1.6,
`kubectl`, `helm`, and Docker.

---

## PART 0 — Provision the infrastructure (VPC, EKS, RDS, ECR)

### Step 0.1: Set your DB password and apply
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars and set a real db_password (or export TF_VAR_db_password instead)

terraform init
terraform plan
terraform apply
```
This takes **15–20 minutes** — EKS cluster creation is slow, that's
normal. It creates:
- A VPC with 2 public + 2 private + 2 database subnets across 2 AZs, one NAT gateway
- An EKS cluster (`automobile-project-dev-eks`) with a managed node group (2× t3.small by default)
- An RDS MySQL instance in the private database subnets, security-grouped to only accept traffic from the EKS nodes
- An ECR repository for the app image
- The IAM role (IRSA) + Helm install for the AWS Load Balancer Controller, so `k8s/ingress.yaml` will actually provision a real ALB later

### Step 0.2: Point kubectl at the new cluster
```bash
terraform output configure_kubectl
# copy-paste and run the command it prints, e.g.:
aws eks update-kubeconfig --name automobile-project-dev-eks --region ap-south-1

kubectl get nodes    # should show 2 Ready nodes
kubectl -n kube-system get pods | grep aws-load-balancer   # should be Running
```

### Step 0.3: Note down the outputs you'll need next
```bash
terraform output ecr_repository_url
terraform output rds_endpoint
```
Keep these handy for Part A below.

---

## PART A — The Application

### Step 1: Create the database schema
```bash
# Get your RDS endpoint from the AWS console or Terraform output
mysql -h <DB_HOST> -u <DB_USER> -p automobile_db < app/schema.sql
```
Before running it, generate a real password hash and paste it into
`schema.sql` in place of the placeholder:
```bash
python3 -c "import bcrypt; print(bcrypt.hashpw(b'YourStrongPassword', bcrypt.gensalt()).decode())"
```

### Step 2: Build and push the Docker image
The ECR repo already exists from Part 0 (`terraform output ecr_repository_url`).
```bash
cd app
docker build -t automobile-app:latest .

ECR_URL=$(cd ../terraform && terraform output -raw ecr_repository_url)

aws ecr get-login-password --region ap-south-1 | \
  docker login --username AWS --password-stdin "${ECR_URL%/*}"

docker tag automobile-app:latest "${ECR_URL}:latest"
docker push "${ECR_URL}:latest"
```

### Step 3: Fill in real secrets
Edit `k8s/service.yaml`, replace the `Secret` block's placeholder values
with your real RDS endpoint (`terraform output -raw rds_endpoint` from
Part 0) and the DB credentials from your `terraform.tfvars`, and
generate a real `SECRET_KEY`:
```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
```
(In a real production setup, don't hand-edit this file — use External
Secrets Operator pulling from AWS Secrets Manager, matching your
earlier project setup. The plain Secret here is the "from scratch,
get it working first" path.)

### Step 4: Point the Deployment at your image
In `k8s/deployment.yaml`, replace:
```
image: <YOUR_ECR_REPO_URI>:latest
```
with the real ECR URI from Step 2.

### Step 5: Deploy to EKS
```bash
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml
kubectl apply -f k8s/hpa.yaml
```

### Step 6: Get your URL
```bash
kubectl -n automobile get ingress automobile-app-ingress
```
Wait 2–3 minutes for the ALB to provision, then copy the `ADDRESS`
column — that's your ALB DNS name. Open:
```
http://<alb-dns-name>/login
```
Log in with the admin username/password you hashed in Step 1. You'll
land on `/dashboard`, matching your screenshot. Use **Add Material** to
create materials, **Materials** to bump assembled/delivered counts,
**Production Tracking** to log daily output (feeds the trend chart),
**Inventory** and **Reports** for read-only views.

### Sanity checks if something's wrong
```bash
kubectl -n automobile get pods
kubectl -n automobile logs deploy/automobile-app
kubectl -n automobile exec -it deploy/automobile-app -- curl -s localhost:5000/readyz
```
`/readyz` returning `not-ready` almost always means the pod can't reach
RDS — check security group rules (RDS SG must allow inbound 3306 from
the EKS node/pod security group) and that the Secret's `DB_HOST` is
correct.

---

## PART B — Monitoring & Observability

### Step 7: Install Prometheus + Grafana + Alertmanager
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

helm install kube-prom-stack prometheus-community/kube-prometheus-stack \
  -n monitoring -f monitoring/prometheus/kube-prometheus-stack-values.yaml
```
Before running this, edit `kube-prometheus-stack-values.yaml`:
- set a real `grafana.adminPassword`
- fill in your Slack webhook URL and/or SMTP details under `alertmanager.config.receivers`

This single chart gives you CPU/memory/pod-count metrics for free
(via node-exporter + kube-state-metrics + cAdvisor) — nothing extra to
configure for those three.

### Step 8: Wire up the app's own metrics (latency, error rate)
The Flask app already exposes `/metrics` via `prometheus-flask-exporter`
(built into `app.py`). Apply the ServiceMonitor so Prometheus scrapes it:
```bash
kubectl apply -f monitoring/prometheus/servicemonitor.yaml
```
Check it's being scraped:
```bash
kubectl -n monitoring port-forward svc/kube-prom-stack-kube-prometheus 9090
# open http://localhost:9090/targets — look for "automobile-app-monitor"
```

### Step 9: Load the alert rules
```bash
kubectl apply -f monitoring/prometheus/alert-rules.yaml
```
This creates alerts for: pod CPU > 80%, pod memory > 80%, P95 latency
> 1s, 5xx error rate > 5%, zero available replicas, and crash-looping
pods. They route through the Alertmanager config from Step 7 (Slack for
`severity=critical`, email for everything).

### Step 10: Import the Grafana dashboard
```bash
kubectl -n monitoring port-forward svc/kube-prom-stack-grafana 3000:80
# open http://localhost:3000, log in as admin / <the password you set>
```
Grafana → Dashboards → New → Import → upload
`monitoring/grafana-dashboards/automobile-app-dashboard.json`. It has
panels for CPU/pod, memory/pod, available pod count, request rate, P95
latency, and 5xx error rate.

### Step 11: Centralized logs (Loki + Promtail)
```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm install loki grafana/loki-stack -n monitoring -f monitoring/loki-stack-values.yaml
```
In Grafana: Connections → Data sources → Add → Loki, URL
`http://loki.monitoring.svc.cluster.local:3100`. Then Explore →
select Loki → query `{namespace="automobile"}` to see every pod's logs
in one place, filterable by pod/container.

*(Alternative: if you'd rather keep logs in CloudWatch instead of
Loki, run `monitoring/terraform-cloudwatch/enable-container-insights.sh
<cluster-name> ap-south-1` instead of installing Loki — it deploys
Fluent Bit and ships logs to CloudWatch Logs under
`/aws/containerinsights/<cluster>/application`.)*

### Step 12: CloudWatch for EC2/RDS/ALB + alarms
```bash
cd monitoring/terraform-cloudwatch
terraform init
terraform apply \
  -var="notification_email=you@example.com" \
  -var="rds_instance_id=<your-rds-identifier>" \
  -var="alb_arn_suffix=<from the ALB, format: app/name/id>" \
  -var="eks_cluster_name=<your-cluster-name>"
```
Confirm the SNS email subscription (check your inbox, click confirm).
This creates alarms for: RDS CPU > 80%, RDS free storage < 2GB, ALB 5xx
count, ALB target response time > 1s, and EKS node CPU > 80% (needs
Container Insights enabled — see the script in that same folder).

### Step 13: Test alerting for real
Don't just trust the YAML — trigger it:
```bash
chmod +x monitoring/test-alerts.sh
./monitoring/test-alerts.sh
```
This kills a pod (watch it recover and confirm no false negative), runs
a CPU stress loop inside a pod for 6 minutes (watch `PodCPUHigh` fire),
and gives you a one-liner to hammer a bad URL to trip the error-rate
alert. Watch alerts arrive:
```bash
kubectl -n monitoring port-forward svc/kube-prom-stack-kube-alertmanager 9093
# open http://localhost:9093 — confirm the alert appears, then check Slack/email
```

---

## Tearing it all down (and rebuilding again)
Since you keep deleting everything to rebuild clean, do it in this order
so nothing gets orphaned and re-billed:
```bash
helm uninstall loki -n monitoring        # if installed
helm uninstall kube-prom-stack -n monitoring   # if installed
kubectl delete -f k8s/                   # app resources, drops the ALB
cd terraform
terraform destroy                        # tears down EKS, RDS, VPC, ECR, IAM roles
```
Destroying the ingress/ALB *before* `terraform destroy` matters — Terraform
doesn't know about the ALB the Load Balancer Controller created for you,
and `terraform destroy`-ing the VPC while an ALB still references its
subnets will hang or fail.

## Project layout
```
automobile-dashboard/
├── terraform/                    # VPC, EKS, RDS, ECR, ALB controller IRSA
│   ├── versions.tf
│   ├── variables.tf
│   ├── vpc.tf
│   ├── eks.tf
│   ├── rds.tf
│   ├── ecr.tf
│   ├── irsa.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── app/                          # Flask app tier
│   ├── app.py
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── schema.sql
│   ├── templates/                # login, dashboard, materials, etc.
│   └── static/css/style.css
├── k8s/
│   ├── deployment.yaml
│   ├── service.yaml               # + Secret template
│   ├── ingress.yaml                # ALB, no domain
│   └── hpa.yaml
└── monitoring/
    ├── prometheus/
    │   ├── kube-prometheus-stack-values.yaml
    │   ├── servicemonitor.yaml
    │   └── alert-rules.yaml
    ├── grafana-dashboards/automobile-app-dashboard.json
    ├── loki-stack-values.yaml
    ├── terraform-cloudwatch/
    │   ├── main.tf
    │   └── enable-container-insights.sh
    └── test-alerts.sh
```

## What was fixed vs. earlier attempts
- Login now hashes/verifies passwords with `bcrypt` instead of anything
  plaintext or hand-rolled.
- DB credentials come **only** from a Kubernetes Secret / env vars —
  never hardcoded in `app.py`.
- Added `/healthz` (liveness, no DB dependency) and `/readyz`
  (readiness, actually checks DB connectivity) so probes fail correctly
  when RDS is unreachable instead of the pod looking "healthy" while
  broken.
- Ingress has no `host` rule and no ACM/Route53 dependency — it works
  purely off the ALB's generated DNS name, so there's nothing to break
  from a missing domain.
- Gunicorn (not the Flask dev server) runs the app in the container.
- Metrics, alert rules, and the ServiceMonitor's `release` label are
  explicitly matched to the Helm release name — the #1 reason
  ServiceMonitors silently get ignored by Prometheus.
