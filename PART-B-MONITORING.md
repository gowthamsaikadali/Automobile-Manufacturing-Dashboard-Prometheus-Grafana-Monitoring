# Part B — Monitoring & Observability: Full Step-by-Step (PowerShell)

This assumes Part 0 (infrastructure) and Part A (the app) from the main
`README.md` are already done — your EKS cluster is up, `kubectl` is
pointed at it, and the app is running. Run every command below from the
**project root** (the folder containing `app`, `k8s`, `monitoring`,
`terraform` as siblings) unless a step explicitly says `cd` somewhere
else.

---

## Step 6.5 (do this FIRST, before anything else in Part B): install the storage layer

Prometheus, Grafana, and Loki all need to save data to disk
(PersistentVolumeClaims). EKS does not come with the ability to create
disks out of the box — nothing in the infra so far installed it. Two
things fix this, and both are already written for you:

**What changed and why:** `terraform\irsa.tf` now also installs the
**EBS CSI driver** (an EKS addon + its own IAM role) — without this,
any pod asking for a PersistentVolumeClaim just sits in `Pending`
forever with no useful error message. `k8s\storageclass-gp3.yaml` is a
new file that defines the actual `gp3` disk type Kubernetes will
provision on request — the driver gives the *ability*, this file gives
the *recipe*.

```powershell
cd terraform
terraform plan
```
Confirm the plan shows it **adding** (not changing/destroying)
`module.ebs_csi_irsa_role...` and `aws_eks_addon.ebs_csi_driver` — that
confirms you're on the updated `irsa.tf`. Then:
```powershell
terraform apply
```

Now apply the StorageClass itself:
```powershell
cd ..
kubectl apply -f k8s\storageclass-gp3.yaml
kubectl get storageclass
```
You should see a `gp3` entry with `(default)` next to it. If this step
is skipped, every PVC below will silently hang — worth confirming now
rather than debugging it later.

---

## Step 7 — Install Prometheus + Grafana + Alertmanager

### 7.1 Add the Helm repo
```powershell
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### 7.2 Create the monitoring namespace
```powershell
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
```

### 7.3 Edit the values file — exactly what to change and where
Open `monitoring\prometheus\kube-prometheus-stack-values.yaml` in your
editor. There are three specific edits to make:

**Edit 1 — Grafana admin password.** Find this line near the `grafana:`
section:
```yaml
grafana:
  adminPassword: "changeMe123!"   # override via --set or a Secret in real deployments
```
Replace `"changeMe123!"` with a real password of your choosing. This is
what you'll log into Grafana with in Step 10.

**Edit 2 — Email notifications.** Find this block under
`alertmanager.config.receivers`:
```yaml
      - name: default-notifications
        email_configs:
          - to: "you@example.com"
            from: "alertmanager@example.com"
            smarthost: "smtp.gmail.com:587"
            auth_username: "you@example.com"
            auth_identity: "you@example.com"
            auth_password: "REPLACE_WITH_APP_PASSWORD"
            send_resolved: true
```
Change `to`/`from`/`auth_username`/`auth_identity` to your real email
address. For `auth_password`, if you're using Gmail: you cannot use
your normal Gmail password here (Google blocks it) — you need an **App
Password** instead:
1. Go to your Google Account → Security → 2-Step Verification (must be turned on first)
2. Search "App passwords" in the account settings search bar
3. Generate one for "Mail" — Google gives you a 16-character code
4. Paste that 16-character code in as `auth_password` (spaces don't matter)

**Edit 3 — Slack notifications.** Find this block:
```yaml
      - name: slack-critical
        slack_configs:
          - api_url: "https://hooks.slack.com/services/REPLACE/WITH/WEBHOOK"
            channel: "#alerts-prod"
```
To get a real webhook URL:
1. Go to https://api.slack.com/apps → "Create New App" → "From scratch"
2. Name it (e.g. "Automobile Alerts"), pick your workspace
3. Left sidebar → "Incoming Webhooks" → toggle it **On**
4. Click "Add New Webhook to Workspace", pick a channel, authorize
5. Copy the webhook URL it gives you (starts with `https://hooks.slack.com/services/...`)
6. Paste it in as `api_url`, and set `channel` to your actual channel name

If you don't want Slack right now, you can leave this block as-is — it
just means critical alerts will only go to email, not Slack, until you
come back and fill this in.

### 7.4 Install
```powershell
helm install kube-prom-stack prometheus-community/kube-prometheus-stack `
  -n monitoring -f monitoring\prometheus\kube-prometheus-stack-values.yaml
```
This takes 2-3 minutes. The backtick `` ` `` at the end of the first
line is PowerShell's line-continuation character — make sure nothing
comes after it on that line (not even a trailing space), or PowerShell
won't treat the next line as a continuation.

### 7.5 Verify it's actually running
```powershell
kubectl -n monitoring get pods
```
You should see pods like `kube-prom-stack-kube-prometheus-...`,
`kube-prom-stack-grafana-...`, `kube-prom-stack-kube-alertmanager-...`,
plus `node-exporter` pods (one per node) and `kube-state-metrics`, all
showing `Running` with `1/1` or `2/2` under `READY`. If any show
`Pending`, run:
```powershell
kubectl -n monitoring describe pod <pod-name>
```
and check the `Events` section at the bottom — `Pending` at this stage
almost always means Step 6.5 (storage) wasn't actually applied yet.

---

## Step 8 — Wire up the app's own metrics (latency, error rate)

Your Flask app already exposes a `/metrics` endpoint (this is built
into `app\app.py` via `prometheus-flask-exporter` — no code change
needed here). You just need to tell Prometheus to scrape it:

```powershell
kubectl apply -f monitoring\prometheus\servicemonitor.yaml
```

### Verify Prometheus is actually scraping it
```powershell
kubectl -n monitoring port-forward svc/kube-prom-stack-kube-prometheus 9090
```
Leave that running, open a browser to `http://localhost:9090/targets`,
and look for an entry named `automobile/automobile-app-monitor`. It
should show `State: UP`. If it's missing entirely (not even listed),
the most common cause is a label mismatch — check that
`monitoring\prometheus\servicemonitor.yaml` has:
```yaml
metadata:
  labels:
    release: kube-prom-stack   # must exactly match your `helm install <name>` above
```
If you installed the chart under a different release name than
`kube-prom-stack`, this label has to match that name exactly, or
Prometheus won't discover the ServiceMonitor at all. Press `Ctrl+C` in
the terminal to stop the port-forward when you're done checking.

---

## Step 9 — Load the alert rules

```powershell
kubectl apply -f monitoring\prometheus\alert-rules.yaml
```
No file edits needed — this creates alerts for pod CPU > 80%, pod
memory > 80%, P95 request latency > 1s, 5xx error rate > 5%, zero
available replicas, and crash-looping pods, all pre-wired to alert on
the `automobile` namespace.

### Verify the rules loaded
```powershell
kubectl -n monitoring port-forward svc/kube-prom-stack-kube-prometheus 9090
```
Open `http://localhost:9090/rules` — you should see a group called
`automobile-app.rules` with 6 rules listed underneath it. `Ctrl+C` to
stop the port-forward when done.

---

## Step 10 — Import the Grafana dashboard

```powershell
kubectl -n monitoring port-forward svc/kube-prom-stack-grafana 3000:80
```
Leave that running. Open `http://localhost:3000` in your browser.

- **Username:** `admin`
- **Password:** whatever you set in Step 7.3, Edit 1

Once logged in:
1. Left sidebar → **Dashboards**
2. Click **New** (top right) → **Import**
3. Click **Upload dashboard JSON file**
4. Select `monitoring\grafana-dashboards\automobile-app-dashboard.json` from your project folder
5. On the next screen, it'll ask you to pick a data source for the Prometheus queries — select **Prometheus** (there should only be one option, auto-added by the Helm chart)
6. Click **Import**

You now have one dashboard with 7 panels: CPU per pod, memory per pod,
available pod count, request rate, P95 latency, 5xx error rate, and pod
restarts — all scoped to the `automobile` namespace. `Ctrl+C` in the
terminal to stop the port-forward when you're done looking (or leave it
running while you work).

---

## Step 11 — Centralized logs (Loki + Promtail)

```powershell
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm install loki grafana/loki-stack -n monitoring -f monitoring\loki-stack-values.yaml
```
No file edits needed for this one — `loki-stack-values.yaml` is
already configured to skip installing its own Grafana (you already have
one from Step 7) and points Promtail at every pod's logs automatically.

### Verify and connect it to Grafana
```powershell
kubectl -n monitoring get pods | Select-String "loki|promtail"
```
You should see one `loki-0` pod and one `loki-promtail-...` pod **per
node** in your cluster, all `Running`.

Now add Loki as a data source in Grafana (the Helm chart doesn't do
this automatically since Grafana was installed by a different release):
1. In the Grafana UI (still at `http://localhost:3000` — re-run the
   port-forward from Step 10 if you closed it): left sidebar →
   **Connections** → **Data sources** → **Add data source**
2. Select **Loki**
3. Under **URL**, enter exactly: `http://loki.monitoring.svc.cluster.local:3100`
4. Click **Save & test** at the bottom — it should show a green checkmark
5. Left sidebar → **Explore**, select **Loki** as the data source (top
   left dropdown), and enter this query: `{namespace="automobile"}`
6. Click **Run query** — you should see live log lines from your app pods

*(If you'd rather send logs to CloudWatch instead of running Loki,
skip this whole step and instead run Step 11-alt below — don't do
both, pick one.)*

### Step 11-alt (alternative to Loki): CloudWatch Container Insights
```powershell
cd monitoring\terraform-cloudwatch
.\enable-container-insights.ps1 -ClusterName automobile-project-dev-eks -Region ap-south-1
```
If PowerShell blocks the script from running:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```
then re-run the `.\enable-container-insights.ps1` line. Logs then show
up in the AWS Console under CloudWatch → Log groups →
`/aws/containerinsights/automobile-project-dev-eks/application`.

---

## Step 12 — CloudWatch alarms for RDS/ALB/EKS nodes

This is separate Terraform from your main infra — it lives in its own
folder so it can be applied/destroyed independently.

### 12.1 Gather the four values you'll need
```powershell
# Your RDS instance identifier:
cd ..\..\terraform
terraform output rds_endpoint
# The identifier is the part before the first dot, e.g. "automobile-project-dev-db"

# Your EKS cluster name:
terraform output eks_cluster_name
```
For the ALB ARN suffix, run this (needs the ALB DNS name from Part A,
Step 6):
```powershell
aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(DNSName, 'automobile')].LoadBalancerArn" --output text
```
That prints a full ARN like
`arn:aws:elasticloadbalancing:ap-south-1:123456789012:loadbalancer/app/automobile-project-dev-alb/abc123def456`
— you only need the part starting from `app/`, e.g.
`app/automobile-project-dev-alb/abc123def456`.

### 12.2 Apply
```powershell
cd ..\monitoring\terraform-cloudwatch
terraform init
terraform apply `
  -var="notification_email=you@example.com" `
  -var="rds_instance_id=automobile-project-dev-db" `
  -var="alb_arn_suffix=app/automobile-project-dev-alb/abc123def456" `
  -var="eks_cluster_name=automobile-project-dev-eks"
```
Replace each value with your real ones from Step 12.1. Same PowerShell
backtick rule as before — nothing after the `` ` `` on each line.

### 12.3 Confirm the email subscription
Check the inbox for the address you passed as `notification_email` —
AWS SNS sends a confirmation email titled "AWS Notification -
Subscription Confirmation". You **must** click the "Confirm
subscription" link in it, or you'll never actually receive alarm
emails even though the alarm exists.

This creates 5 CloudWatch alarms: RDS CPU > 80%, RDS free storage <
2GB, ALB 5xx count > 10 in 5 min, ALB target response time > 1s, and
EKS node CPU > 80% (the last one needs Container Insights from Step
11-alt to have real data — if you did Loki instead, that specific alarm
just won't have metrics to alarm on, the other 4 still work fine).

---

## Step 13 — Test alerting for real

Don't just trust that the YAML is correct — actually trigger it and
watch it fire end-to-end.

```powershell
cd ..\..
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\monitoring\test-alerts.ps1
```

This script does three things:
1. **Kills a pod** — watch it get replaced automatically:
   ```powershell
   kubectl -n automobile get pods -w
   ```
   (`Ctrl+C` to stop watching once you see a new pod come up `Running`)
2. **Spikes CPU inside a pod** for 6 minutes in the background — after
   ~5 minutes, `PodCPUHigh` should fire.
3. **Prints a command** to hammer a bad URL and trip the error-rate
   alert — this one you run yourself, it's not automatic:
   ```powershell
   1..500 | ForEach-Object { try { Invoke-WebRequest -Uri "http://<your-alb-dns>/does-not-exist" -UseBasicParsing } catch {} }
   ```

### Watch alerts actually arrive
```powershell
kubectl -n monitoring port-forward svc/kube-prom-stack-kube-alertmanager 9093
```
Open `http://localhost:9093` — you should see the alert appear in the
UI within a few minutes, then check your email inbox and Slack channel
(if you configured it in Step 7.3) for the actual notification.

If an alert shows as firing in the Alertmanager UI but you never get an
email or Slack message, the alert rules and Prometheus are working —
the problem is specifically in the `alertmanager.config` block you
edited in Step 7.3 (wrong SMTP password, unconfirmed Slack webhook,
etc.), not in the monitoring stack itself.

---

## Quick troubleshooting reference

| Symptom | Likely cause | Where to look |
|---|---|---|
| PVC stuck `Pending` | Step 6.5 skipped | `kubectl get storageclass`, `kubectl describe pvc -n monitoring <name>` |
| ServiceMonitor not in Prometheus targets | `release` label mismatch | `monitoring\prometheus\servicemonitor.yaml` vs your actual `helm install` release name |
| Grafana dashboard shows "No data" | Data source not selected during import, or ServiceMonitor not scraping yet | Re-check Step 10 step 5, re-check Step 8 |
| Alert fires in Alertmanager but no email | Wrong SMTP app password, or `to`/`from` still placeholders | `monitoring\prometheus\kube-prometheus-stack-values.yaml`, Step 7.3 Edit 2 |
| Alert fires but no Slack message | Webhook not authorized to a channel, or still the placeholder URL | Step 7.3 Edit 3 |
| CloudWatch alarms never trigger | SNS email subscription never confirmed | Check inbox for AWS confirmation email, Step 12.3 |
