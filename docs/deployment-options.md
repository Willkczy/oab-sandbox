# Docker and Kubernetes: interpreting the upstream recommendation

Reviewed on 2026-10-25 against upstream OpenAB main at
[`20830d5`](https://github.com/openabdev/openab/commit/20830d5dfb24cff96599001832164152a22bbb71).
This source review does not certify the custom Docker deployment or test a
Kubernetes replacement.

## The upstream requirement

[Security by Design](https://github.com/openabdev/openab/blob/20830d5dfb24cff96599001832164152a22bbb71/DESIGN.md#4-security-by-design)
describes Kubernetes Pods as the intended isolation model and requires a sandbox
outside local development. The [local-development disclaimer](https://github.com/openabdev/openab/blob/20830d5dfb24cff96599001832164152a22bbb71/docs/local-dev.md)
limits native host execution to development/debugging and warns against running
the agent with the host user's permissions in production.

Kubernetes is the main documented route, including the install/upgrade workflow.
The [README](https://github.com/openabdev/openab/blob/20830d5dfb24cff96599001832164152a22bbb71/README.md#kubernetes-deployment)
also documents an official [ECS Fargate route](https://github.com/openabdev/openab/blob/20830d5dfb24cff96599001832164152a22bbb71/docs/oabctl.md).
The reviewed files do not establish a blanket prohibition on Docker Engine.
The community statement supplied by the operator was not independently retrieved;
its precise intent should not be inferred from these files.

## What runs here

```text
Intel macOS -> Colima Linux VM -> Docker Engine -> four containers
```

`run.sh` uses `docker run`; launchd supervises the VM and foreground agent.
Kubernetes does not manage this coach. Docker/OCI images can be used by either
deployment mode, so the image format alone does not distinguish them.

This deployment implements restrictions explicitly: uid 1000, dropped
capabilities, no-new-privileges, read-only agent rootfs, tmpfs, memory/PID limits,
an internal network, a Squid egress gate and a separate token broker. The
[live audit](audits/2026-10-25.md) records what passed and the remaining gaps.
Those custom controls remain our responsibility to maintain.

## Compare the operating responsibilities

| Concern | Current Docker deployment | Kubernetes deployment |
|---|---|---|
| Configuration | Shell scripts and launchd maintained here | Upstream Helm templates, values, Secrets, ConfigMaps and PVCs |
| Agent restrictions | Explicit, measured Docker flags | Security contexts and resource specifications, with cluster enforcement |
| Egress | Agent has no external route; Squid applies a domain allowlist | Requires explicit policy, an enforcing network plugin, and a domain-aware gate |
| Cloud credentials | Private key isolated in the broker | Preserve that boundary or design workload identity; a Secret mounted into the agent is different |
| Recovery | launchd and a gateway-traffic watchdog | Controllers restart/recreate workloads; useful application probes still need to be provided |
| Storage | Host vault clone, named volumes and reviewed Git sync | PVC/storage lifecycle and the same review boundary must be designed |
| Operations | Fewer components for one bot | More consistent multi-agent management, with additional control-plane, network and storage maintenance |
| Host sleep | Suspends the service and watchdog | A cluster confined to the same sleeping VM stops serving too |

The Kubernetes column lists available mechanisms, not guarantees obtained just
by creating a Pod.

## What the reviewed chart actually supplies

The [chart values](https://github.com/openabdev/openab/blob/20830d5dfb24cff96599001832164152a22bbb71/charts/openab/values.yaml)
set non-root execution, RuntimeDefault seccomp, read-only rootfs, no privilege
escalation and dropped capabilities. However, agent `resources` defaults to
`{}`. The chart templates contain no NetworkPolicy, and the main
[Deployment template](https://github.com/openabdev/openab/blob/20830d5dfb24cff96599001832164152a22bbb71/charts/openab/templates/deployment.yaml)
defines no startup, readiness or liveness probes. It fixes `replicas: 1` and
`strategy: Recreate`, so the default installation does not provide multi-replica
availability or rolling updates. External cluster policies can add controls;
the chart by itself does not establish them.

[Kubernetes NetworkPolicy documentation](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
states that outbound traffic is allowed until a Pod is selected by an egress
policy. Enforcement requires a supporting network plugin. Standard policies
select Pods, namespaces, IPs and ports; they do not automatically reproduce
Squid's hostname allowlist and access log.

[Containers in one Pod share a network namespace](https://kubernetes.io/docs/concepts/workloads/pods/#pod-networking).
Putting all four roles into one Pod would therefore change the network boundary:
ordinary Pod NetworkPolicy cannot grant the proxy external access while denying
that same network access to its sibling agent container. Preserve separate Pods
or explicitly design and verify an equivalent enforcement layer.

## Practical choice for this coach

For one coach on the existing Intel Mac, retaining the hardened Docker layout
while fixing measured defects is a reasonable near-term choice. Kubernetes in
the same Colima VM would add operating work without curing host sleep,
coaching-rule failures, stale notes or provider-authentication fragility.

For long-lived use on an always-awake Linux host, particularly with several
agents or an existing maintained cluster, K3s/Helm becomes more useful: it follows
upstream's operating conventions and standardizes workload/configuration
management. This is an engineering judgment, not a claim that upstream endorses
this custom setup or that an immediate migration is required.

[K3s minimum server requirements](https://docs.k3s.io/installation/requirements#hardware)
are two CPU cores and 2 GB RAM, excluding workloads. That is a planning baseline,
not measured consumption. The current VM has two CPUs and 4 GiB; measure
control-plane and peak workload headroom before adding a cluster there.

A migration must carry or replace the broker, egress gate, relay behavior,
vault sync/review, session-retention policy and meaningful liveness checks.
Re-test key absence and direct egress on the target. Installing the stock chart
alone does not perform that migration.

## Image maintenance remains necessary on either platform

Upstream's [2026-10-23 release notes](https://github.com/openabdev/openab/releases/tag/openab-0.10.0-beta.6)
describe security-driven Node rebuilds, including Node 22.23.4. The audited agent
image has Node 22.23.1. Review fixed images and compatibility independently of
the orchestrator choice; a different scheduler does not patch an existing image.
Re-run authentication and coaching checks after changing pi/auth dependencies.

The release is named `0.10.0-beta.6`, even though its API `prerelease` flag is
false. A beta is not a validated stable replacement merely because of that flag.
Its existence also does not, by itself, establish that the deployed 0.9 minor
line is unsupported; consult the [security policy](https://github.com/openabdev/openab/blob/20830d5dfb24cff96599001832164152a22bbb71/SECURITY.md)
and image channels when preparing a tested upgrade.
