**step-by-step guide** to launch an EKS cluster using **eksctl**, 
I’ll use:

* **Region**: `ap-south-1`
* **Cluster name**: `demo-eks-cluster` 

---

## STEP 0 – Prerequisites

### 0.1 IAM and AWS account

You need:

* An AWS account
* An IAM user/role with permissions to create:

  * EKS
  * EC2
  * IAM roles
  * CloudFormation stacks

### 0.2 Install & configure tools

On your laptop/jump host:

```bash
aws --version          # AWS CLI v2.x
kubectl version --client
eksctl version
```

If any is missing, install as per AWS docs. ([AWS Documentation][3])

Configure AWS CLI:

```bash
aws configure
# enter Access key, Secret key
# Default region: ap-south-1
# Output format: json
```

Confirm:

```bash
aws sts get-caller-identity
```

---

## STEP 1 – Decide how you want to create the cluster

There are **two main ways** with eksctl ([AWS Documentation][2])

1. **Simple one-line command** (fastest, good for demos)
2. **Config file (`cluster.yaml`)** (recommended for repeatable/prod setups)

I’ll give you **both**, you can choose what to teach.

---

# OPTION A – Simple One-Line Cluster (Quick Start)

This is the fastest way: eksctl will create:

* EKS control plane
* A **managed nodegroup** (by default)
* VPC, subnets, security groups (if you don’t specify custom VPC) ([AWS Documentation][2])

### 1A.1 Create the cluster

```bash
eksctl create cluster \
  --name demo-eks-cluster \
  --region ap-south-1 \
  --nodegroup-name ng-1 \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 4 \
  --managed
```

Notes:

* `demo-eks-cluster` → must be letters/numbers/hyphens, start with a letter ([AWS Documentation][2])
* This will take ~10–20 minutes to finish (control plane + nodes).

You can *also* go ultra-simple:

```bash
eksctl create cluster
```

That uses your **default region** and creates a simple cluster with a managed nodegroup of two `m5.large` nodes. ([AWS Documentation][2])

---

### 1A.2 Verify the cluster

Check eksctl view:

```bash
eksctl get cluster
```

Update kubeconfig (usually already done for you, but safe to run):

```bash
aws eks update-kubeconfig \
  --name demo-eks-cluster \
  --region ap-south-1
```

Verify Kubernetes access:

```bash
kubectl get nodes
kubectl get ns
```

You should see 2 worker nodes in `Ready` status.

---

# OPTION B – Using a cluster.yaml Config File (Recommended)

This is the **AWS-documented way** to use eksctl in a GitOps / IaC style: you define the cluster in YAML, then run `eksctl create cluster -f cluster.yaml`. ([AWS Documentation][3])

---

## STEP 1B – Create the cluster.yaml file

Create the file:

```bash
cat <<EOF > cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: demo-eks-cluster
  region: ap-south-1

nodeGroups:
  - name: ng-1
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 1
    maxSize: 3
    ssh:
      allow: false   # set true if you want SSH access to nodes
EOF
```

Key points:

* `metadata.name` → cluster name
* `metadata.region` → your AWS region
* `nodeGroups` → defines worker nodes (instance type, counts, etc.) ([AWS Documentation][3])

---

## STEP 2B – (Optional) Dry Run

Validate YAML before actually creating the cluster:

```bash
eksctl create cluster -f cluster.yaml --dry-run
```

This shows what eksctl will do, but does **not** create anything yet. ([AWS Documentation][3])

---

## STEP 3B – Create the cluster

Now actually create it:

```bash
eksctl create cluster -f cluster.yaml
```

Wait for it to finish (10–20 mins typically). ([AWS Documentation][3])

---

## STEP 4B – Verify the cluster

List clusters:

```bash
eksctl get cluster
```

Update kubeconfig (if needed):

```bash
aws eks update-kubeconfig \
  --name demo-eks-cluster \
  --region ap-south-1
```

Check nodes:

```bash
kubectl get nodes
```

Your cluster is ready. ([AWS Documentation][3])

---

# STEP 5 – (Optional) Use an existing VPC

If you don’t want eksctl to create a VPC, you can reference an existing one in `cluster.yaml` by specifying subnets: ([AWS Documentation][2])

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: demo-eks-cluster
  region: ap-south-1

vpc:
  subnets:
    private:
      ap-south-1a: { id: subnet-aaaa1111 }
      ap-south-1b: { id: subnet-bbbb2222 }

nodeGroups:
  - name: ng-1-workers
    labels: { role: workers }
    instanceType: t3.medium
    desiredCapacity: 2
    privateNetworking: true
```

Then:

```bash
eksctl create cluster -f cluster.yaml
```

---

# STEP 6 – Deleting the Cluster (Cleanup)

To avoid AWS costs, delete the cluster when done.

With config file:

```bash
eksctl delete cluster -f cluster.yaml --wait
```

Or by name:

```bash
eksctl delete cluster \
  --name demo-eks-cluster \
  --region ap-south-1 \
  --wait
```

`--wait` is recommended so you see any deletion errors (for example, PDB blocking node draining). ([AWS Documentation][2])

---

