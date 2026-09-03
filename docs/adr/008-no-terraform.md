# 008. Ansible only, no Terraform

**Status:** Accepted
**Date:** 2026-09-03

## Context

Configuration management is needed for four existing servers. Terraform
is the usual companion to Ansible.

## Decision

Use **Ansible alone**. No Terraform.

## Consequences

Positive: one tool, one mental model. Ansible configures what is already
there, which is exactly the problem at hand. No state file to store, lock or
corrupt.

Negative: the servers themselves are not described as code. If they are lost,
replacements are provisioned by hand before Ansible runs, which lengthens
recovery. Recorded in the disaster recovery procedure.

## Alternatives considered

**Terraform** — earns its place when infrastructure is created and
destroyed through an API. These four servers already exist and are long-lived;
Terraform would manage a state file describing resources it never created.

Revisit if the infrastructure moves to a cloud provider with an API, where
rebuilding a host from code would materially shorten recovery.
