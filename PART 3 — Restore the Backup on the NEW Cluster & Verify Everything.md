
# **PART 3 — Restore the Backup on the NEW Cluster & Verify Everything**

This part assumes:

* You finished **Part 1** (backup on old cluster)
* You finished **Part 2** (installed Velero on new cluster + verified old backups)
* You now want to **restore the entire application** from backup.

We will restore:

* **All namespaces**
* **All Deployments/Services/ConfigMaps**
* **All CRDs (if any)**
* **All PersistentVolumeClaims (PVCs)**
* **EBS snapshots → PV creation → pod mounting**

---

#  **1. Pre-Restore Sanity Check (Mandatory)**

Run these commands on **NEW** cluster:

### **Velero Ready?**

```bash
kubectl -n velero get pods
velero backup-location get
```

PHASE must be: **Available**

### **Backups visible?**

```bash
velero backup get
```

Expected backup:

```
efk-demo-full-20251129   Completed
shop-prod-full-20251129  Completed
```

### **Check EBS Snapshot Plugin**

```bash
velero plugin get
```

Must show:

```
velero.io/aws                <VolumeSnapshotter>
```

### **Check snapshots exist in AWS**

```bash
aws ec2 describe-snapshots --owner-ids self --query "Snapshots[*].{ID:SnapshotId,Time:StartTime}" --output table
```

---

#  **2. Run Restore Command**

Choose the backup name you want to restore, e.g.:

```
efk-demo-full-20251129
```

Run the restore:

```bash
velero restore create efk-restore-20251129 \
  --from-backup efk-demo-full-20251129
```

Check restore status:

```bash
velero restore get
velero restore describe efk-restore-20251129 --details
```

Expected:

```
STATUS: Completed
ERRORS: 0
WARNINGS: <some warnings usually okay>
```

 Warnings are normal.
Errors should be **0**.

---

#  **3. Verify Namespaces Restored**

```bash
kubectl get ns
```

You should see your application namespaces:

```
shop-prod
mysql
logging
whatever existed in old cluster
```

If only required namespaces appear → GOOD.

---

#  **4. Verify Kubernetes Resources Restored**

### **Deployments**

```bash
kubectl get deploy -A
```

### **Pods**

```bash
kubectl get pods -A
```

### **Services**

```bash
kubectl get svc -A
```

### **Secrets**

```bash
kubectl get secret -n shop-prod
```

### **ConfigMaps**

```bash
kubectl get cm -n shop-prod
```

Everything must be present.

---

#  **5. Verify PVC → PV → Pod Restoration**

This is VERY important.

### **PVCs**

```bash
kubectl get pvc -A
```

You should see PVCs like:

```
mysql-data
orders-db
elasticsearch-master
```

### **PVs**

```bash
kubectl get pv
```

PVs must be **Bound**.

### **Pod Logs**

Check if pods using volumes are running:

```bash
kubectl logs mysql-0 -n shop-prod
```

If MySQL starts successfully → snapshot restoration succeeded.

---

#  **6. Verify Application Works End-to-End**

### **Get frontend service**

```bash
kubectl -n shop-prod get svc shop-frontend
```

If it's LoadBalancer:

```bash
curl http://<EXTERNAL-IP>
```

You should see the **shop frontend page**.

### **Test orders API**

```bash
kubectl -n shop-prod get svc orders-api
curl http://<EXTERNAL-IP>/api/orders
```

Expected:
Your API should return JSON output.

---

#  **7. Deep Health Verification Checklist**

### **Check pod restarts**

```bash
kubectl get pods -A | grep -v Running
```

### **Check events**

```bash
kubectl get events -A --sort-by='.lastTimestamp'
```

### **Check MySQL connectivity**

From inside a pod:

```bash
kubectl exec -it mysql-0 -n shop-prod -- mysql -u root -p
```

Try listing DBs:

```sql
show databases;
```

If DB exists → restore fully successful.

---

#  **8. Common Issues & FIXES**

###  **PV stuck in Pending**

Solution:
EBS CSI driver not installed or IAM policy missing.
Reinstall add-on:

```bash
aws eks create-addon --cluster-name efk-new --addon-name aws-ebs-csi-driver
```

---

###  **Restore says Completed but PVC missing**

Reason: snapshot plugin not loaded.

Fix:

```bash
velero install --plugins velero/velero-plugin-for-aws:v1.10.0 ...
```

---

###  **Pod stuck CrashLoopBackOff because ConfigMap/Secret missing**

Fix:
Check restore logs:

```bash
velero restore logs <restore-name>
```

---

###  **Node agents not running**

Fix:

```bash
kubectl -n velero get daemonset
kubectl -n velero delete pod -l name=velero
```

---

#  **9. FINAL CONFIRMATION CHECKLIST (Must Pass)**

Before you tell students “RESTORE SUCCESSFUL,” verify:

###  Namespaces restored

###  Deployments restored

###  Pods running

###  Services working

###  PVC → PV restored

###  Application working end-to-end

###  S3 backup still intact

###  No Failed pods

###  Database restored from snapshot

###  Frontend reachable via LoadBalancer

If all PASS → **Full restore successful.**

---

#  Final Result

You now have:

* Old cluster → FULL backup
* New cluster → Full restore
* Data + PVCs + Apps all restored
* Velero working end-to-end
* A perfect demo for students


