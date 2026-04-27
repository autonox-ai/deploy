# Secure Supply Chain Integration Guide

## Autonox Container Images via JFrog Artifactory

**Document Classification:** Customer-Facing
**Version:** v1.0 (Enterprise / Regulated Environments)
**Audience:** Security, Platform, DevOps, Infrastructure, Compliance

---

## Executive Summary

This document defines the **secure, controlled, and auditable** method for consuming **Autonox** container images using **JFrog Artifactory** as the single supply‑chain gateway.

The model ensures that:

* Production clusters **never pull directly from external registries**
* All artifacts are **scanned, governed, and approved** using customer‑owned JFrog policies
* Images are **immutable, signed, and traceable**
* The architecture aligns with common **SOC 2 / ISO 27001 control expectations**

Autonox distributes images using open **OCI standards**, allowing customers to retain **full control** over what enters their environment.

---

## 1. Purpose

To define a **secure supply‑chain integration pattern** where Autonox container images are consumed **exclusively via JFrog Artifactory**, acting as a controlled proxy and policy‑enforcement point.

---

## 2. Security Architecture — Proxy Model

Autonox follows a **proxy‑only model** in which **JFrog Artifactory** is the sole component allowed to communicate with external registries.

> **CI Security Note:** Autonox images are built and published **only via GitHub Actions–based CI/CD**, with no external build systems, manual steps, or chained pipelines.

### 2.1 High‑Level Flow

```
Autonox GitHub CI (GitHub Actions)
   ↓
GitHub Container Registry (OCI)
   ↓
JFrog Artifactory (Remote Repository)
   ↓
JFrog Artifactory (Local / Virtual – Approved)
   ↓
Customer Production Clusters
```

**Key Principle:** Production workloads never require outbound access to external registries.

---

## 3. Upstream Registry

Autonox publishes container images to **GitHub Container Registry (GHCR)**, used strictly as an **OCI‑compliant distribution endpoint**.

* **Registry URL:** `https://ghcr.io`
* **Namespace:** `autonox-ai/*`
* **Protocol:** HTTPS (TLS 1.2+)

This integration interacts **only with the OCI registry layer** and does **not** access GitHub repositories, APIs, or user identities.

---

## 4. JFrog Artifactory Configuration

### 4.1 Required Repositories

Customers SHOULD configure:

**Docker Remote Repository**

| Setting | Value |
| --- | --- |
| **Package Type** | Docker |
| **Upstream URL** | `https://ghcr.io` |
| **Include Pattern** | `autonox-ai/**` |
| **User Name** | **Vendor-provided Service Account** (`autonox-registry-bot`) |
| **Password / Token** | **Vendor-provided Access Token** (PAT) |

> The include pattern is **mandatory** to restrict upstream access to Autonox artifacts only.

**Docker Local Repository** — for approved / promoted images
**Docker Virtual Repository** — single internal pull endpoint

---

### 4.2 Authentication Model

* Vendor‑managed **machine credentials** (not user accounts)
* Pull‑only scope, limited to `autonox-ai/*`
* Stored and encrypted **entirely within JFrog**

Customers do not manage GitHub users, tokens, or lifecycle.

---

## 5. Image Naming & Versioning

### 5.1 Naming Convention (1:1 Source ↔ Artifact)

Autonox enforces a **1:1 mapping between GitHub repositories and published OCI image names**.

> **Rule:** The repository name and the container image name MUST be identical.

This eliminates naming drift and enables **automated provenance verification**, ensuring that every container image can be mechanically traced to its exact source repository without manual lookup.

```
ghcr.io/autonox-ai/<repository>:<version>

```

Examples:

```
ghcr.io/autonox-ai/exporters:1.2.0
ghcr.io/autonox-ai/warehouse:1.2.0
ghcr.io/autonox-ai/flows:1.2.0

```

GitHub repositories:

```
github.com/autonox-ai/exporters
github.com/autonox-ai/warehouse
github.com/autonox-ai/flows

```

The **`autonox-ai` registry namespace** provides the required vendor attribution for:

* Kubernetes manifests
* JFrog Xray / SOC alerts
* Audit and compliance evidence

All examples in documentation and production deployments MUST use the **fully‑qualified image reference** (registry + namespace + repository).

---

### 5.2 Versioning Rules

* Semantic Versioning (SemVer)
* **Immutable tags**
* No `:latest`

Examples:

```
1.2.0          # Stable release
1.2.1          # Security / patch
1.2.0-build.7  # Internal traceability
```

Tags are never overwritten.

---

## 6. Supply‑Chain Security

### 6.1 Vulnerability Management

* CI‑time scanning performed before release
* Releases blocked on **Critical** vulnerabilities
* Fixes published as new immutable versions

Customers are expected to re‑scan using **JFrog Xray** and enforce internal policies.

---

### 6.2 Image Integrity

* All images are signed using **Sigstore / Cosign**
* Signatures published alongside images
* SBOMs (SPDX / CycloneDX) available upon request

Signature verification may be enforced during promotion or admission.

---

## 7. Runtime Security Profile

| Control              | Status                 |
| -------------------- | ---------------------- |
| Non‑root execution   | Yes                    |
| Minimal base image   | Yes                    |
| Read‑only filesystem | Supported              |
| Privilege escalation | Disabled               |
| Shell availability   | Removed where possible |

---

## 8. Operational Model (Recommended)

1. Image cached via **JFrog Remote**
2. Scanned and evaluated by Xray
3. Approved image promoted to **Local**
4. Production pulls **only from Local / Virtual**

Original image digests are preserved end‑to‑end.

---

## 9. Compliance Alignment (Non‑Certifying)

This integration model **supports customer compliance efforts** by aligning with common expectations in:

* SOC 2 (change management, least privilege, integrity)
* ISO 27001 (secure development, supplier security, artifact control)

No certification claims are made.

---

## 10. Shared Responsibility Model

| Area                        | Owner    |
| --------------------------- | -------- |
| Image build & signing       | Autonox  |
| Image publication           | Autonox  |
| Registry policy & promotion | Customer |
| Runtime hardening           | Customer |

---

## 11. Support

* **Security:** [security@autonox.ai](mailto:security@autonox.ai)
* **Support:** [support@autonox.ai](mailto:support@autonox.ai)

---

## 12. Document Status

| Version | Status                             |
| ------- | ---------------------------------- |
| v1.0    | Approved for enterprise deployment |

---

## Appendix A: Quick Setup (JFrog CLI)

For platform teams using the `jf` CLI, you can automate this configuration:

```bash
# Variables
export AUTONOX_USER="autonox-registry-bot"
export AUTONOX_TOKEN="ghp_..." # Value from secure note

# Create Remote Repository
jf rt repo-create --rclass remote \
  --package-type docker \
  --url https://ghcr.io \
  --user $AUTONOX_USER \
  --password $AUTONOX_TOKEN \
  --includes-pattern "autonox-ai/**" \
  --repo-key "autonox-remote"
  ```