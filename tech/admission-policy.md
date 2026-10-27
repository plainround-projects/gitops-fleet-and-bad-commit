# ValidatingAdmissionPolicy and CEL

## 1. What it is

A **ValidatingAdmissionPolicy** is a Kubernetes rule that the API server evaluates for every create or update of the objects it matches, before the object is stored. The rule is an expression in **CEL** (Common Expression Language), a small, safe language for conditions. A **binding** says where the policy applies and what to do on a violation. No extra program runs: it is part of the API server (stable since Kubernetes 1.30).

## 2. Why this repository uses it

The lesson's fourth step: a manifest with a privileged container, or an image from outside the `plainround/` registry prefix, is refused by every cluster's API server with the policy's own message, whether it arrives through Argo CD or through `kubectl run`. The policy is delivered to every cluster by its own ApplicationSet.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `manifests/policy/no-privileged.yaml` | the policy and its binding |
| `manifests/hub/appset-policy.yaml` | delivers `policy/` to every cluster |
| `manifests/hub/projects.yaml` | the `fleet-policy` project may create the two kinds |
| `scripts/runbook/04-policy.sh` | stages a violating commit and shows both paths refused |
| `tests/unit` | check the rules by reading the file |

## 4. How it works underneath

- `matchConstraints.resourceRules` say which API groups, resources and operations the policy looks at (here Deployments and Pods on CREATE and UPDATE).
- `variables` name reusable CEL expressions. `validations` is a list of expressions that must all evaluate to **true**; when one is false the request is rejected with its `message`.
- A **ValidatingAdmissionPolicyBinding** attaches a policy to a scope (`matchResources`, here every namespace except the system ones) and sets `validationActions` (`Deny` refuses; `Warn` and `Audit` only report).
- `failurePolicy: Fail` means that if the policy itself cannot be evaluated, the request is refused (fail closed).
- CEL basics used here: `has(x.y)` tests that a field exists; `list.all(c, predicate)` is true when the predicate holds for every element; `a ? b : c` is a conditional; `string.startsWith('x')`.

## 5. Walkthrough of this repository's use

```yaml
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["deployments"]
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
```
Look at Deployments (group `apps`) and Pods (the core group, written `""`) when they are created or changed.

```yaml
  variables:
    - name: containers
      expression: "has(object.spec.template) ? object.spec.template.spec.containers : object.spec.containers"
```
A Deployment keeps its containers under `spec.template.spec`, a Pod directly under `spec`. This one variable gets the container list from whichever object it is.

```yaml
  validations:
    - expression: >-
        variables.containers.all(c, !has(c.securityContext) || !has(c.securityContext.privileged) ||
        c.securityContext.privileged == false)
      message: "privileged containers are not allowed"
    - expression: "variables.containers.all(c, c.image.startsWith('plainround/'))"
      message: "images must come from plainround/"
```
Rule 1: for every container, either it has no `securityContext`, or no `privileged` field, or `privileged` is `false`. The `>-` is a YAML folded block scalar that joins the two lines into one expression. Rule 2: every image starts with `plainround/`.

```yaml
kind: ValidatingAdmissionPolicyBinding
spec:
  policyName: no-privileged-or-foreign-images
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-public", "kube-node-lease", "local-path-storage", "argocd"]
```
`Deny` refuses. The namespace selector excludes the system namespaces and `argocd`: otherwise the cluster's own components (whose images are not `plainround/`) would be refused.

In `04-policy.sh privileged` the script edits the Deployment to add `privileged: true` (and `allowPrivilegeEscalation: true`, or the built-in validation would refuse it first, with a different message), commits, pins staging and production to it, and waits for each stage's sync to **fail**. It checks that each message contains the policy text, then runs `kubectl run attacker --privileged` directly in each cluster and extracts `denied the request: ...` from the error: the policy applies to people too, not only to the controller. Because the policy is in `main` and every cluster's `policy-<name>` Application tracks `main`, no cluster can have a different policy.

## 6. Try it yourself

1. `kubectl --context k3d-fleet-dev get validatingadmissionpolicy,validatingadmissionpolicybinding` : both objects.
2. `kubectl --context k3d-fleet-dev -n web run x --image=docker.io/library/nginx:1.27 --restart=Never` : denied: `images must come from plainround/`.
3. `kubectl --context k3d-fleet-dev -n web run y --image=plainround/web:1.0.0 --privileged --restart=Never` : denied: `privileged containers are not allowed`.
4. `kubectl --context k3d-fleet-dev -n web run z --image=plainround/web:1.0.0 --restart=Never` : created (then `kubectl delete pod z`).
5. `scripts/runbook/04-policy.sh privileged` then `... revert` : the full flow.

## 7. Mistakes people make

- Applying the policy to system namespaces and breaking the cluster. The binding excludes them.
- Using `Warn` and thinking it blocks anything.
- A policy that differs per cluster: here one folder and one ApplicationSet deliver it.
- Testing only through the controller. The `kubectl run` check shows the policy guards every route.

## 8. Check yourself

1. What language are the rules written in?
   *Answer:* CEL, the Common Expression Language.
2. What does the binding add to the policy?
   *Answer:* Where it applies and the action on violation (`Deny`, `Warn`, `Audit`).
3. Why exclude `kube-system`?
   *Answer:* The cluster's own images do not start with `plainround/`; they would be refused.
4. What does `failurePolicy: Fail` mean?
   *Answer:* If the policy cannot be evaluated, the request is refused.
5. Why does the policy refuse a `kubectl run` as well as an Argo CD sync?
   *Answer:* It runs in the API server, which every route passes through.

## 9. Further reading

- Validating admission policy: <https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/> (stable in Kubernetes 1.30; this repository uses 1.35). CEL: <https://kubernetes.io/docs/reference/using-api/cel/>.
