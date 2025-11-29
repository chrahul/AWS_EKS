
# **PART 2 — Install Velero on NEW Cluster & Connect to Old Backups**

## **0. Goal of Part 2**

By the end of this section, you will:

* Launch a brand-new EKS cluster
* Install Velero
* Configure Velero to use the **same S3 bucket / prefix** as the OLD cluster
* Verify that Velero can **see the old backups**

 No restore yet — restore will be in Part 3.

---

# **1. Prerequisites**

From your admin EC2 / workstation, you must have:

* AWS CLI
* kubectl
* velero
* eksctl

Check:

```bash
aws sts get-caller-identity
velero version
```

You must also know:

* **S3 bucket name**
* **prefix** → always `velero/`
* **IAM Role ARN** created in Part 1 → example:
  `arn:aws:iam::<ACCOUNT_ID>:role/VeleroRole`

Verify:

```bash
echo $VELERO_BUCKET
echo $VELERO_ROLE_ARN
```

If not exported, re-export manually:

```bash
export VELERO_BUCKET=<YOUR_BUCKET_NAME>
export VELERO_ROLE_ARN=<VELERO_ROLE_ARN_FROM_PART1>
export AWS_REGION=ap-south-1
```

---

# **2. Create NEW EKS Cluster**

We will create the new cluster named:

```
efk-new
```

Create config:

```bash
cat > eks-new.yaml << 'EOF'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: efk-new
  region: ap-south-1
  version: "1.30"

iam:
  withOIDC: true

managedNodeGroups:
  - name: ng-1
    instanceType: t3.medium
    desiredCapacity: 3
    minSize: 3
    maxSize: 5
    volumeSize: 20
    privateNetworking: true
EOF
```

Create cluster:

```bash
eksctl create cluster -f eks-new.yaml
```

Verify:

```bash
kubectl get nodes -o wide
```

Nodes must be `Ready`.

---

# **3. Install AWS EBS CSI Driver (Required for Velero PVC Restore)**

Install add-on:

```bash
aws eks create-addon \
  --cluster-name efk-new \
  --addon-name aws-ebs-csi-driver \
  --region $AWS_REGION
```

If it remains stuck, attach the policy (same steps as Part 1):

Find node role:

```bash
aws iam list-roles \
  --query "Roles[?contains(RoleName, 'NodeInstanceRole')].RoleName" \
  --output table
```

Attach policy:

```bash
aws iam attach-role-policy \
  --role-name <NODE_ROLE> \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
```

Restart controllers:

```bash
kubectl delete pod -n kube-system -l app=ebs-csi-controller
```

Verify:

```bash
kubectl get pods -n kube-system | grep ebs
```

---

# **4. Install Velero on NEW Cluster Using SAME Bucket**

## **4.1. Get new cluster’s OIDC provider (important)**

```bash
export CLUSTER_NAME=efk-new

OIDC_URL=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --query "cluster.identity.oidc.issuer" \
  --output text)

echo $OIDC_URL
```

 You **MUST** check that `VeleroRole` trust policy already contains:

```
system:serviceaccount:velero:velero
```

If it was created correctly in Part 1 → NO change needed.

If not → update trust policy EXACTLY as in Part 1.

---

# **4.2. Install Velero Using Same Bucket & Prefix**

This is very important:

* **Same bucket**
* **Same prefix: velero**
* **Same IAM role**

Run:

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.10.0 \
  --bucket $VELERO_BUCKET \
  --backup-location-config region=$AWS_REGION \
  --snapshot-location-config region=$AWS_REGION \
  --use-node-agent \
  --prefix velero \
  --no-secret \
  --sa-annotations eks.amazonaws.com/role-arn=$VELERO_ROLE_ARN
```

Expected output → resources created.

---

# **4.3. Verify Velero Pods**

```bash
kubectl -n velero get pods
```

Expected:

* `velero-xxxx` → Running
* `node-agent-xxxx` → Running

---

# **4.4. Verify Velero Backup Storage Location**

```bash
velero backup-location get
```

Expected:

```
PHASE: Available
```

If it shows Available → Velero can read S3 successfully.

---

# **4.5. Verify that Velero can "see" old backups**

```bash
velero backup get
```

You should see backups you took on OLD cluster, e.g.:

```
efk-demo-full-20251129   Completed
shop-prod-full-20251129  Completed
```

This confirms:

* NEW cluster Velero is correctly connected
* IRSA is correct
* Bucket access is correct

 **This is the goal of Part 2** — and you achieved it.

---

# **5. Health Check Commands Before Restore (Must Pass)**

Run these checks:

### Check Velero SA annotation

```bash
kubectl -n velero get sa velero -o yaml | grep role-arn
```

Must show your IAM role.

### Check S3 prefix

```bash
aws s3 ls s3://$VELERO_BUCKET/velero/
```

Must show backup folders.

### Check backup details

```bash
velero backup describe efk-demo-full-20251129 --details
```

No errors.

### Check PVC snapshot existence

```bash
velero backup describe <backup> --details | grep Snapshot
```

If everything is good, you are ready for Part 3.

---

#  Summary of Part 2

You now have:

* NEW EKS cluster (`efk-new`)
* EBS CSI installed
* Velero installed using SAME bucket + prefix
* Velero SA mapped to SAME IAM role
* Verified Velero can read old backups
* Backup-location PHASE = **Available**
* Backup list visible on the NEW cluster

This means your **restore will work**.

---

# **Ready for Part 3?**

Part 3 will cover:

* How to Restore
* Validating MySQL PVC restoration
* Re-creating PVs from snapshots
* Verifying Shop Application
* Testing Frontend & APIs
* Deep restore verification checklist


