# Architecture

**Category:** architecture  
**Last updated:** 2026-10-23
**Audience:** platform architects, ops on rota

## TL;DR

Trust-anchor bootstrap between a customer AWS account and AxelSpire’s deployment pipeline. Applied **once** per customer account (CloudShell setup scripts) before other 3AM stacks. Scripts under `_scripts/` are the SoT for created resources.

## Overview

| Variant | Where to run |
| --- | --- |
| `customer-org-setup.sh` | Customer Org management account (then assume into 3AM child) |
| `single-account-setup.sh` | Same account that is the 3AM workload |

Outputs a JSON hand-off for AxelSpire. Security model / review: `docs/REVIEWING.md`. After bootstrap, product stacks are composed via `3am-deployments` / onboarding.

## Update log

Human-facing product history for operators. **Criterion links** live in the AxelSpire `3am-design-model` delivery log (`evidence/delivery-log.yaml`), not in this file.

| Date (UTC) | Summary | PR |
| --- | --- | --- |
| 2026-10-18 | Dependabot path fix for readiness SEC.04 | [#26](https://github.com/Axelspire/3am-infra-bootstrap/pull/26) |
| 2026-10-23 | Add default-branch gitleaks secret-scan CI (SEC.02.L2.b) | TBD |
