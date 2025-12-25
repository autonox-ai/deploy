# autonox-ai/deploy

This repository contains **deployment assets** for Autonox and related optional dependencies.

Principles:
- We ship **reusable building blocks** (bases + generic overlays).
- Customers assemble deployments using their own **environment overlays** (namespace, storage class, sizing, secrets).
- Nothing here should require editing vendor files; override using Kustomize overlays/patches.

Currently included:
- `dist/kustomize/third-party/pgvector` — a simple Postgres+pgvector StatefulSet (not an operator).
