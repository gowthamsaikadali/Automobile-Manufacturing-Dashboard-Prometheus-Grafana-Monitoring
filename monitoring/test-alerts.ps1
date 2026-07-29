# Deliberately trigger failures to confirm alerting actually fires end-to-end.
# Run: .\monitoring\test-alerts.ps1
# (If PowerShell blocks it: Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass)

$NS = "automobile"

Write-Host "== Test 1: Kill a pod (expect PodDown / restart alert if it doesn't recover) =="
$podToKill = kubectl -n $NS get pods -l app=automobile-app -o jsonpath='{.items[0].metadata.name}'
kubectl -n $NS delete pod $podToKill
Write-Host "Watch:              kubectl -n $NS get pods -w"
Write-Host "Watch Alertmanager: kubectl -n monitoring port-forward svc/kube-prom-stack-kube-alertmanager 9093"

Write-Host ""
Write-Host "== Test 2: Spike CPU inside a pod (expect PodCPUHigh alert after ~5 min) =="
$pod = kubectl -n $NS get pod -l app=automobile-app -o jsonpath='{.items[0].metadata.name}'
Write-Host "Stressing pod: $pod"
Start-Job -ScriptBlock {
    param($ns, $podName)
    kubectl -n $ns exec $podName -- sh -c "yes > /dev/null & yes > /dev/null & sleep 360; kill %1 %2"
} -ArgumentList $NS, $pod | Out-Null
Write-Host "CPU stress running in the background inside $pod for 6 minutes."

Write-Host ""
Write-Host "== Test 3: Force 5xx errors to trip HighErrorRate / ALB 5xx alarm =="
Write-Host "Hit a nonexistent route in a loop for a few minutes, e.g.:"
Write-Host '  1..500 | ForEach-Object { try { Invoke-WebRequest -Uri "http://<ALB-DNS>/does-not-exist" -UseBasicParsing } catch {} }'

Write-Host ""
Write-Host "Check firing alerts anytime with:"
Write-Host '  kubectl -n monitoring exec -it deploy/kube-prom-stack-kube-prometheus -- wget -qO- http://localhost:9090/api/v1/alerts'
