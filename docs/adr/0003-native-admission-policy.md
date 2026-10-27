# 0003. Native ValidatingAdmissionPolicy instead of Kyverno or Gatekeeper

## Context

The lesson asks for an admission policy in every cluster that rejects privileged pods and images from outside a registry, "a Kyverno or Gatekeeper policy". Four kind clusters share one Docker VM.

## Decision

Use the Kubernetes API server's built-in `ValidatingAdmissionPolicy` (CEL, generally available since 1.30): one policy and one binding in `policy/`, no webhook, no pods, no certificates. The rules are the same two the lesson names, with the same kind of message, and the admission decision is made by the API server itself, so there is no `failurePolicy` gap while a webhook's pods start.

## Alternatives

- **Kyverno.** About 500 MB of pods per cluster plus webhooks, so 1.5 GB more across the three clusters, for the same two rules.
- **Gatekeeper.** The same trade; it also needs a constraint template per rule.

## Consequences

- The rejection message reads `ValidatingAdmissionPolicy '...' with binding '...' denied request: privileged containers are not allowed`, not Kyverno's `validate.kyverno.svc` text shown in the lesson.
- Mutation, generation and image signature checks are out of reach of this policy type; the README names them as the reason to move to Kyverno when they are needed.
- The policy covers Deployments and Pods and leaves the system namespaces alone.
