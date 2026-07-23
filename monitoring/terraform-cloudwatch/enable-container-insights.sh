#!/usr/bin/env bash
# Enables CloudWatch Container Insights on an existing EKS cluster by
# deploying the CloudWatch agent + Fluent Bit as a DaemonSet (for both
# metrics AND centralized logs going into CloudWatch Logs).
#
# Usage: ./enable-container-insights.sh <cluster-name> <region>

set -euo pipefail
CLUSTER_NAME="${1:?Usage: $0 <cluster-name> <region>}"
REGION="${2:?Usage: $0 <cluster-name> <region>}"

curl -s https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluent-bit-quickstart.yaml \
  | sed "s/{{cluster_name}}/${CLUSTER_NAME}/;s/{{region_name}}/${REGION}/" \
  | kubectl apply -f -

echo "Container Insights + Fluent Bit deployed."
echo "View metrics: CloudWatch console -> Container Insights -> Performance monitoring"
echo "View logs:    CloudWatch console -> Log groups -> /aws/containerinsights/${CLUSTER_NAME}/application"
