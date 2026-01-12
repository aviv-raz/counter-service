# Storage, Scaling, and Concurrency Design Notes (EKS)

This document explains the trade-offs behind my storage and scaling choices for the **counter-service** application, and what would be required to safely scale it further.

---

## Background: how the service persists state

The service stores its counter in a JSON file (default: `/data/counter.json`).  
To prevent corrupted writes, the application uses **exclusive file locking** and an **atomic write pattern**:

- A dedicated lock file (`counter.lock`) is used to acquire an exclusive lock.
- The counter is written to a temporary file and then atomically replaced (`tmp -> replace`).

This approach ensures that even when multiple requests hit the service concurrently (e.g., threads inside the same process), only one writer updates the counter at a time, and readers never see a partially-written file.

---

## Why I chose EBS CSI (and what it solves)

I installed **EBS CSI Driver** and used an **EBS-backed PVC** for simplicity and operational convenience in EKS.

### What this choice solves
- **Simple persistence model**: the counter file is persisted via a standard Kubernetes PVC.
- **Easy provisioning**: a StorageClass can dynamically provision EBS volumes (e.g., gp3).
- **Good for single-writer patterns**: EBS is ideal when the workload is effectively single-node / single-writer.

### The key limitation
EBS volumes are typically mounted in Kubernetes as **ReadWriteOnce (RWO)**, which effectively means:

- The volume can be mounted read-write by **one node at a time**.
- In practice, this strongly pushes the workload to **a single replica** (or multiple pods only if they are forced onto the same node, which is not a robust HA pattern).

✅ **Result:** With EBS CSI, I run **1 replica** of the application to guarantee consistent, safe access to the persistent counter file.

---

## When this design will NOT work (and why)

### 1) Multiple replicas (multi pods) that share the same storage
If I scale the Deployment to multiple replicas while using EBS (RWO):

- Pods may be scheduled on different nodes.
- The same volume cannot be mounted read-write across nodes concurrently.
- The second pod will typically fail to mount (or the scheduler will prevent placement), so the scale-out won’t behave as intended.

✅ **Conclusion:** With **EBS CSI**, safe persistence via a single shared file strongly implies **replicas = 1**.

---

## What I would change to support multiple replicas without changing application code

### Option A — Switch storage to EFS CSI (RWX)
To allow **multiple pods on multiple nodes** to mount the same shared filesystem, the storage must support **ReadWriteMany (RWX)**.

- EFS CSI provides an NFS-based shared filesystem (RWX).
- All replicas can mount `/data` simultaneously.
- The Python code does **not** need to change, because it already implements file locking and atomic writes.

✅ This is the most direct path to “multi replicas + shared file” while keeping the current persistence approach.

### Option B — Move state to an external data store (recommended for real scale)
Another common approach is to remove file-based state entirely and use a strongly-consistent store with atomic operations, e.g.:

- DynamoDB (atomic UpdateItem / conditional writes)
- Redis (INCR)
- RDS with transactions

✅ This also avoids shared filesystem concerns and usually scales better than file-based state.

---

## Replicas vs Workers: locking and metrics trade-offs

There are two independent scaling axes:

1) **Replicas (Pods)**: horizontal scaling at the Kubernetes level  
2) **Workers/Threads inside a Pod**: concurrency within a single Pod (Gunicorn workers, threads)

Below are the key implications for **file locking** and **Prometheus metrics**.

---

## Multi pods (multiple replicas)

### File locking
If I choose **multi pods** and they share the same file, I need a locking mechanism that is safe **across pods/nodes**:

- With **EBS CSI**, this is blocked by RWO (single-node attachment), so multi pods sharing the same PV is not a viable design.
- With **EFS CSI**, shared RWX is possible. File locks can work across clients, and my code already implements locking + atomic replace.

If I choose **multi pods** without shared filesystem and I still want a single global counter, then I must move state into a distributed store (DynamoDB/Redis/etc.).

**Summary (multi pods):**
- EBS: ❌ not suitable for shared file across pods (RWO)
- EFS: ✅ suitable (RWX), code can stay the same
- External DB: ✅ suitable, best long-term scalability

### Metrics
If I choose **multi pods**, metrics are naturally fine:

- Prometheus scrapes each pod endpoint independently.
- Each pod exposes its own counters/histograms.
- Aggregation happens at query-time in PromQL (sum/rate/etc.).

✅ **Conclusion:** multi pods = **metrics are straightforward**.

---

## Multi workers (multiple processes inside the same Pod)

### File locking
If I choose **multi workers** (e.g., Gunicorn `workers>1`), multiple processes may access the same file:

- On Linux, file locking can coordinate access across processes.
- The code uses file locking, so it protects the counter file from concurrent writers.

✅ **Conclusion:** multi workers = file locking can be fine (assuming all workers mount the same path).

### Metrics
This is where it gets tricky.

Prometheus Python client libraries typically do **not** aggregate metrics across multiple worker processes “out of the box” in a single, clean way.

Common solutions include:
- Using a multi-process mode (requires special setup and filesystem directory for metrics state)
- Pushgateway (push model instead of scrape model)
- Running a single worker per pod and scaling via replicas instead

❗ **Conclusion:** multi workers can require additional work for correct metrics aggregation.

---

## My final runtime choice (and why)

### Pods / replicas
- ✅ I chose **1 replica** because I use **EBS CSI (RWO)** and persist state in a single file.
- This guarantees stable persistence semantics and avoids cross-node shared storage requirements.

### Workers / threads
- ✅ I chose **a single worker process** (no multi-worker processes) because I do not currently implement metrics aggregation across workers.
- ✅ I do use **threads=4**, and the file-locking mechanism supports concurrent requests safely by serializing writes.

**Why threads=4 is acceptable here**
- Threads share the same process memory space.
- The app-level file lock ensures only one writer updates the file at a time.
- Prometheus metrics remain consistent because there is a single process exporting them.

---

## Summary of trade-offs

### Current design (what I implemented)
- Storage: **EBS CSI (RWO)**
- Replicas: **1**
- Worker model: **single worker process**
- Concurrency: **threads=4**
- Pros:
  - Simple operational model
  - Safe persistence with a single-writer pattern
  - Metrics are simple and accurate
- Cons:
  - No horizontal scaling via multiple replicas (unless storage/state approach changes)

### To support multiple replicas (recommended path)
- Switch to **EFS CSI (RWX)** for shared file storage **or**
- Move state to **DynamoDB/Redis** for a proper distributed counter

In both cases, the **Python locking/atomic write code does not need to change**, because it already follows safe update semantics. The main change is the storage/state backend to support horizontal scaling.
