#!/usr/bin/env bash
# Deliberately trigger failures to confirm alerting actually fires end-to-end.
# Run each test one at a time and watch Alertmanager / Slack / email.

set -euo pipefail
NS="automobile"

echo "== Test 1: Kill a pod (expect PodDown / restart alert if it doesn't recover) =="
kubectl -n "$NS" delete pod -l app=automobile-app --field-selector=status.phase=Running | head -n1
echo "Watch: kubectl -n $NS get pods -w"
echo "Watch Alertmanager UI: kubectl -n monitoring port-forward svc/kube-prom-stack-kube-alertmanager 9093"

echo ""
echo "== Test 2: Spike CPU inside a pod (expect PodCPUHigh alert after ~5 min) =="
POD=$(kubectl -n "$NS" get pod -l app=automobile-app -o jsonpath='{.items[0].metadata.name}')
echo "Stressing pod: $POD"
kubectl -n "$NS" exec "$POD" -- sh -c "yes > /dev/null & yes > /dev/null & sleep 360; kill %1 %2" &
echo "CPU stress running in background inside $POD for 6 minutes."

echo ""
echo "== Test 3: Force 5xx errors to trip HighErrorRate / ALB 5xx alarm =="
echo "curl a nonexistent route in a loop for a few minutes, e.g.:"
echo '  for i in $(seq 1 500); do curl -s -o /dev/null http://<ALB-DNS>/does-not-exist; done'

echo ""
echo "Check firing alerts anytime with:"
echo '  kubectl -n monitoring exec -it deploy/kube-prom-stack-kube-prometheus -- \'
echo '    wget -qO- http://localhost:9090/api/v1/alerts'
