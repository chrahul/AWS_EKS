$ cat eks-cluster-health-check.sh

#!/usr/bin/env bash
# EKS / Kubernetes Cluster Health Check
# -------------------------------------
# - Captures cluster, node, pod, addon, autoscaler, ingress and CSI info
# - Automatically finds "problematic" pods (non Running/Completed/Succeeded)
#   and dumps describe + logs for each
# - Writes everything into a timestamped report file
#
# Usage:
#   chmod +x eks-cluster-health-check.sh
#   ./eks-cluster-health-check.sh
#
# Optional env:
#   REPORT_DIR=/path/to/dir ./eks-cluster-health-check.sh

set -uo pipefail

REPORT_DIR="${REPORT_DIR:-./cluster-health-reports}"
mkdir -p "${REPORT_DIR}"

TS="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="${REPORT_DIR}/cluster-health-${TS}.log"

log() {
  # Log to both stdout and file
  echo -e "$@" | tee -a "${REPORT_FILE}"
}

hr() {
  log "\n============================================================\n"
}

log "Kubernetes Cluster Health Check - $(date)"
log "Report file: ${REPORT_FILE}"
hr

# ---------------------------------------------------------------------------
# 0. Context & basic cluster info
# ---------------------------------------------------------------------------
log "0. Cluster context & basic info\n"

log ">> kubectl config current-context"
kubectl config current-context 2>&1 | tee -a "${REPORT_FILE}"

log "\n>> kubectl cluster-info"
kubectl cluster-info 2>&1 | tee -a "${REPORT_FILE}" || log "WARN: cluster-info failed (API server issue?)"

log "\n>> kubectl version --short"
kubectl version --short 2>&1 | tee -a "${REPORT_FILE}"

hr

# ---------------------------------------------------------------------------
# 1. Node health
# ---------------------------------------------------------------------------
log "1. Node Health\n"

log ">> kubectl get nodes -o wide"
kubectl get nodes -o wide 2>&1 | tee -a "${REPORT_FILE}"

log "\n>> Node status summary (STATUS column):"
kubectl get nodes --no-headers 2>/dev/null \
  | awk '{print $2}' | sort | uniq -c | tee -a "${REPORT_FILE}"

log "\n>> Node conditions (Ready / MemoryPressure / DiskPressure / PIDPressure)\n"

kubectl get nodes -o name 2>/dev/null | while read -r NODE; do
  log "---- ${NODE} ----"
  kubectl describe "${NODE}" 2>/dev/null \
    | sed -n '/Conditions:/,/Addresses:/p' \
    | tee -a "${REPORT_FILE}"
  log ""
done

hr

# ---------------------------------------------------------------------------
# 2. Pod status across namespaces
# ---------------------------------------------------------------------------
log "2. Pod Status Across Namespaces\n"

log ">> kubectl get pods -A"
kubectl get pods -A 2>&1 | tee -a "${REPORT_FILE}"

log "\n>> Non-healthy pods (STATUS != Running/Completed/Succeeded)\n"

# Find problematic pods
PROBLEM_PODS=$(kubectl get pods -A --no-headers 2>/dev/null \
  | awk '$4 !~ /Running|Completed|Succeeded/ {print $1","$2","$4}')

if [[ -z "${PROBLEM_PODS}" ]]; then
  log "No problematic pods found. All pods are Running/Completed/Succeeded."
else
  echo "${PROBLEM_PODS}" | while IFS=',' read -r NS POD STATUS; do
    log "---- Problematic pod: ${NS}/${POD} (STATUS=${STATUS}) ----"

    log ">> kubectl describe pod ${POD} -n ${NS}"
    kubectl describe pod "${POD}" -n "${NS}" 2>&1 | tee -a "${REPORT_FILE}"

    log "\n>> kubectl logs ${POD} -n ${NS} --tail=100"
    kubectl logs "${POD}" -n "${NS}" --tail=100 2>&1 | tee -a "${REPORT_FILE}" || \
      log "WARN: Failed to get current logs for ${NS}/${POD}"

    log "\n>> kubectl logs ${POD} -n ${NS} --previous --tail=100 (if restarted)"
    kubectl logs "${POD}" -n "${NS}" --previous --tail=100 2>&1 | tee -a "${REPORT_FILE}" || \
      log "INFO: No --previous logs for ${NS}/${POD} (maybe no restarts)."

    log ""
  done
fi

hr

# ---------------------------------------------------------------------------
# 3. Core add-ons: CoreDNS, VPC CNI, kube-proxy, Pod Identity Agent
# ---------------------------------------------------------------------------
log "3. Core Add-ons (kube-system)\n"

# 3.1 CoreDNS
log "3.1 CoreDNS\n"
log ">> kubectl get pods -n kube-system -l k8s-app=kube-dns"
kubectl get pods -n kube-system -l k8s-app=kube-dns 2>&1 | tee -a "${REPORT_FILE}"

log "\n>> kubectl describe deploy coredns -n kube-system | egrep 'Image:|Replicas|Available'"
kubectl describe deploy coredns -n kube-system 2>/dev/null \
  | egrep "Image:|Replicas|Available" \
  | tee -a "${REPORT_FILE}" || log "INFO: coredns deployment describe failed (check if name differs)."

hr

# 3.2 VPC CNI (aws-node)
log "3.2 AWS VPC CNI (aws-node DaemonSet)\n"
log ">> kubectl get pods -n kube-system -l k8s-app=aws-node"
kubectl get pods -n kube-system -l k8s-app=aws-node 2>&1 | tee -a "${REPORT_FILE}"

log "\n>> kubectl describe ds aws-node -n kube-system | egrep 'Image:|Desired Number of Nodes'"
kubectl describe ds aws-node -n kube-system 2>/dev/null \
  | egrep "Image:|Desired Number of Nodes|Number of Nodes" \
  | tee -a "${REPORT_FILE}" || log "INFO: aws-node DaemonSet describe failed (check name/namespace)."

hr

# 3.3 kube-proxy
log "3.3 kube-proxy DaemonSet\n"
log ">> kubectl get pods -n kube-system -l k8s-app=kube-proxy"
kubectl get pods -n kube-system -l k8s-app=kube-proxy 2>&1 | tee -a "${REPORT_FILE}"

log "\n>> kubectl describe ds kube-proxy -n kube-system | egrep 'Image:|Desired Number of Nodes'"
kubectl describe ds kube-proxy -n kube-system 2>/dev/null \
  | egrep "Image:|Desired Number of Nodes|Number of Nodes" \
  | tee -a "${REPORT_FILE}" || log "INFO: kube-proxy DaemonSet describe failed."

hr

# 3.4 EKS Pod Identity Agent
log "3.4 EKS Pod Identity Agent\n"
log ">> kubectl get pods -n kube-system -l app=eks-pod-identity-agent"
kubectl get pods -n kube-system -l app=eks-pod-identity-agent 2>&1 | tee -a "${REPORT_FILE}"

log "\n>> kubectl describe ds eks-pod-identity-agent -n kube-system | egrep 'Image:|Desired Number of Nodes'"
kubectl describe ds eks-pod-identity-agent -n kube-system 2>/dev/null \
  | egrep "Image:|Desired Number of Nodes|Number of Nodes" \
  | tee -a "${REPORT_FILE}" || log "INFO: eks-pod-identity-agent DaemonSet describe failed."

hr

# ---------------------------------------------------------------------------
# 4. Cluster Autoscaler, Ingress Controllers, CSI Drivers
# ---------------------------------------------------------------------------
log "4. Cluster Autoscaler, Ingress, CSI Drivers\n"

# 4.1 Cluster Autoscaler
log "4.1 Cluster Autoscaler\n"
log ">> kubectl get pods -A | grep -i autoscaler || echo 'No autoscaler pods found'"
kubectl get pods -A 2>/dev/null | grep -i autoscaler \
  | tee -a "${REPORT_FILE}" || log "INFO: No autoscaler pods found."

# Try common namespace/name combo for logs (best-effort)
if kubectl get deploy -n kube-system 2>/dev/null | grep -q "cluster-autoscaler"; then
  log "\n>> kubectl logs -n kube-system deploy/cluster-autoscaler --tail=100"
  kubectl logs -n kube-system deploy/cluster-autoscaler --tail=100 2>&1 \
    | tee -a "${REPORT_FILE}" || log "WARN: Failed to get cluster-autoscaler logs."
fi

hr

# 4.2 Ingress Controllers
log "4.2 Ingress Controllers\n"
log ">> kubectl get pods -A | egrep -i 'ingress|alb-controller|nginx-ingress' || echo 'No ingress controller pods found'"
kubectl get pods -A 2>/dev/null \
  | egrep -i "ingress|alb-controller|nginx-ingress" \
  | tee -a "${REPORT_FILE}" || log "INFO: No ingress/alb/nginx-ingress pods found."

log "\n>> kubectl get ingress -A"
kubectl get ingress -A 2>&1 | tee -a "${REPORT_FILE}"

hr

# 4.3 CSI Drivers (EBS, EFS, S3, etc.)
log "4.3 CSI Drivers\n"

log ">> kubectl get csidrivers"
kubectl get csidrivers 2>&1 | tee -a "${REPORT_FILE}" || log "INFO: csidrivers API not available."

log "\n>> kubectl get pods -n kube-system | egrep 'csi|ebs|efs|s3' || echo 'No CSI driver pods visible'"
kubectl get pods -n kube-system 2>/dev/null \
  | egrep -i "csi|ebs|efs|s3" \
  | tee -a "${REPORT_FILE}" || log "INFO: No CSI driver pods matched (check naming)."

hr

# ---------------------------------------------------------------------------
# 5. Events & Rollouts / Maintenance activity
# ---------------------------------------------------------------------------
log "5. Events & Rollout / Maintenance Activity\n"

log ">> Recent cluster events (last 50, all namespaces)"
kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -n 50 \
  | tee -a "${REPORT_FILE}" || log "INFO: Failed to get events (RBAC or API restriction)."

log "\n>> Deployment status snapshot (all namespaces)"
kubectl get deploy -A 2>&1 | tee -a "${REPORT_FILE}"

hr

log "Health check complete."
log "Report saved to: ${REPORT_FILE}"
