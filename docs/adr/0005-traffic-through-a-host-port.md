# 0005. The outage traffic goes through a host port

## Context

Step 6 sends traffic to the production app while the controller is down. If the traffic went through `kubectl port-forward` or the API server's service proxy, a failure there would look like an app outage.

## Decision

The app's Service is a NodePort (30080) and each kind cluster publishes it on a host port (dev 18101, staging 18102, production 18103). The traffic loop is `curl` against `127.0.0.1:18103/healthz`: no controller and no API server in the path.

## Consequences

- The Service type differs from a typical production Service; the base says why.
- The same ports serve the fourth cluster's check (18104).
