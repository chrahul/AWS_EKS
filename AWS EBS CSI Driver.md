

#  **AWS EBS CSI Driver – Complete Guide (Installation, IAM, Verification & Troubleshooting)**

This documentation explains:

What the EBS CSI driver is
Why it is needed for dynamic PV provisioning
How AWS EKS handles CSI driver add-ons
Required IAM permissions
How to install / fix / verify the driver
How to troubleshoot volume provisioning issues
A working checklist for production

---

# 1️ What Is the AWS EBS CSI Driver?

EKS uses the **Amazon EBS CSI driver** to dynamically create and manage **EBS volumes** for Kubernetes **PersistentVolumeClaims (PVCs)**.

Without this driver:

* PVCs will remain in **Pending**
* Pods using volumes (StatefulSets, Deployments) will not start
* Errors like **"External Provisioning Timeout"** will appear

This driver is **mandatory** for:

* Stateful applications (MySQL, MongoDB, Postgres)
* Persistent storage for Deployments
* Any workload using PVC + AWS EBS

---

# 2️ EBS CSI Driver Architecture Overview

### Components:

| Component              | Namespace     | Description                                    |
| ---------------------- | ------------- | ---------------------------------------------- |
| **ebs-csi-controller** | kube-system   | Creates, attaches, deletes EBS volumes         |
| **ebs-csi-node**       | kube-system   | Runs on every node; performs mount/unmount     |
| **StorageClass**       | cluster-wide  | Defines provisioning behavior (gp2, gp3, etc.) |
| **PVC/PV**             | per namespace | Requests storage dynamically                   |

---

# 3️ Installing the AWS EBS CSI Driver

There are **two supported installation methods**:

### **METHOD A: Using EKS Addon (Recommended)**

```bash
aws eks create-addon \
  --cluster-name <CLUSTER_NAME> \
  --addon-name aws-ebs-csi-driver \
  --region <REGION>
```

Check:

```bash
aws eks describe-addon \
  --cluster-name <CLUSTER_NAME> \
  --addon-name aws-ebs-csi-driver \
  --query "addon.status"
```

Status should be:

```
ACTIVE
```

---

# 4️ Required IAM Permission (MOST IMPORTANT STEP)

### Node group IAM role MUST have this policy attached:

```bash
arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
```

This policy allows:

* ec2:CreateVolume
* ec2:AttachVolume
* ec2:DescribeAvailabilityZones
* ec2:DeleteVolume
* etc.

Without this policy → **PV provisioning FAILS**.

---

## 4.1 Identify Node Instance Role

```bash
aws iam list-roles --query "Roles[?contains(RoleName, 'NodeInstanceRole')].RoleName" --output table
```

Example output:

```
eksctl-efk-demo-nodegroup-ng-1-NodeInstanceRole-xp47b2LfZMJp
```

---

## 4.2 Attach Policy

```bash
aws iam attach-role-policy \
  --role-name eksctl-efk-demo-nodegroup-ng-1-NodeInstanceRole-xp47b2LfZMJp \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
```

Verify:

```bash
aws iam list-attached-role-policies \
  --role-name eksctl-efk-demo-nodegroup-ng-1-NodeInstanceRole-xp47b2LfZMJp
```

You MUST see:

```
AmazonEBSCSIDriverPolicy
```

---

# 5️ Restart CSI Controller (Required After IAM Fix)

```bash
kubectl delete pod -n kube-system -l app=ebs-csi-controller
```

Pods will re-create automatically.

Check:

```bash
kubectl get pods -n kube-system | grep ebs
```

Expected:

```
ebs-csi-controller... 5/6 Running
ebs-csi-controller... 5/6 Running
ebs-csi-node...       3/3 Running
```

---

# 6️ Verify Dynamic Provisioning (CRITICAL TEST)

### Step 1 — Check StorageClass

```bash
kubectl get sc
```

Expect:

```
gp2 (default)   provisioner: kubernetes.io/aws-ebs
```

### Step 2 — Deploy an app that uses PVC

Example: MySQL StatefulSet

```bash
kubectl get pvc -n shop-prod
```

Expected:

```
mysql-data-mysql-0   Bound   <PV-NAME>   10Gi   RWO   gp2
```

### Step 3 — Check PV

```bash
kubectl get pv
```

Expected:

```
pvc-xxxx Bound shop-prod/mysql-data-mysql-0
```

### Step 4 — Check Events (to ensure CSI driver provisioned it)

```bash
kubectl describe pvc mysql-data-mysql-0 -n shop-prod | sed -n '/Events:/,$p'
```

You MUST see:

```
External provisioner is provisioning volume
Successfully provisioned volume pvc-xxxx
```

---

# 7️ If PVC Stuck in Pending – Troubleshooting Guide

###  **Reason 1 — IAM Policy Missing (MOST COMMON)**

Error in events:

```
Waiting for a volume to be created...
```

Fix: attach IAM policy
Restart controller pod

---

###  **Reason 2 — EBS CSI Driver Pods Failing**

Check:

```bash
kubectl get pods -n kube-system | grep ebs
```

If controller pod is 0/6 → IAM issue.

---

###  **Reason 3 — AZ mismatch**

EBS volumes are AZ-specific.

Check:

```bash
kubectl describe pvc | grep selected-node
```

Check node AZ:

```bash
kubectl get nodes -L topology.kubernetes.io/zone
```

---

###  **Reason 4 — Wrong StorageClass provisioner**

Should be:

```
ebs.csi.aws.com
```

Not:

```
kubernetes.io/aws-ebs (deprecated)
```

---

# 8️ Checklist for Production EKS Clusters

| Item                 | Should Be                     | Verified? |
| -------------------- | ----------------------------- | --------- |
| EKS version          | 1.24+                         |          |
| EBS CSI Driver addon | ACTIVE                        |         |
| Node IAM Role        | `AmazonEBSCSIDriverPolicy`    |          |
| ebs-csi-controller   | Running 5/6                   |          |
| ebs-csi-node         | Running 3/3 on all nodes      |          |
| StorageClass         | provisioner = ebs.csi.aws.com |          |
| PVC binding          | Bound                         |          |
| PV                   | Bound to PVC                  |          |
| Pod                  | Running                       |          |

---

# 9️ Summary (One Line)

> **EBS CSI Driver will work ONLY when your node group IAM role has the `AmazonEBSCSIDriverPolicy`, and the driver pods restart after IAM fix. Once that’s done, PV provisioning becomes instant and reliable.**


