# Enables CloudWatch Container Insights on an existing EKS cluster (CloudWatch
# agent + Fluent Bit DaemonSet - metrics AND centralized logs into CloudWatch Logs).
#
# Usage: .\enable-container-insights.ps1 -ClusterName <name> -Region <region>

param(
    [Parameter(Mandatory = $true)][string]$ClusterName,
    [Parameter(Mandatory = $true)][string]$Region
)

$url = "https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluent-bit-quickstart.yaml"

$manifest = (Invoke-WebRequest -Uri $url -UseBasicParsing).Content
$manifest = $manifest -replace '\{\{cluster_name\}\}', $ClusterName
$manifest = $manifest -replace '\{\{region_name\}\}', $Region

$manifest | kubectl apply -f -

Write-Host "Container Insights + Fluent Bit deployed."
Write-Host "View metrics: CloudWatch console -> Container Insights -> Performance monitoring"
Write-Host "View logs:    CloudWatch console -> Log groups -> /aws/containerinsights/$ClusterName/application"
