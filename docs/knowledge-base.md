# KubeStellar knowledge base

Checked on 7 November 2026 against KubeStellar **v0.30.1** (released 3 November 2026), the architecture and user docs in [kubestellar/docs](https://github.com/kubestellar/docs), and the v0.30.1 README. This is an evaluation note for this repo, not an upstream document.

The short version: KubeStellar is a CNCF Sandbox control plane that copies ordinary Kubernetes objects from one API onto many clusters, chosen by labels. It does not create clusters, schedule replica counts across them, or replace GitOps. The local lab in this repo is how you test whether that copy-and-select job is the one you actually have.

## Decision

Use KubeStellar when the hard part is **the same Kubernetes objects, many clusters**. You keep writing `Deployment`, `Service`, `ConfigMap`, and custom resources with kubectl, Helm, or Kustomize. A `BindingPolicy` says which objects go to which clusters. Clusters stay independent.

Hire a different tool when the hard part is something else:

| The job | Use this | Why KubeStellar is the wrong hire |
| --- | --- | --- |
| Create, upgrade, and delete clusters | Cluster API | KubeStellar assumes the clusters already exist. |
| Split replicas, weight clusters, fail over when one dies | [Karmada](https://www.cncf.io/projects/karmada/) (CNCF Graduated, 3 September 2026) | KubeStellar selects whole clusters. It does not reschedule pods across them. |
| Git is the only interface, and each cluster already has an overlay | Argo CD `ApplicationSet`, or Flux | Both are Graduated. They sync Git. They do not need a second control plane in front of the clusters. |
| You already apply OCM `ManifestWork` and `Placement` | Stay on [Open Cluster Management](https://www.cncf.io/projects/open-cluster-management/) (CNCF Incubating, 4 November 2026) | KubeStellar is a front door on top of OCM, not a replacement for it. |
| Pods should run on another cluster as virtual nodes | Liqo | Different problem: offload, not manifest fan-out. |
| Pods in cluster A must reach pods in cluster B | Submariner or a cloud network | KubeStellar does not connect cluster networks. |

KubeStellar composes with the tools above. Cluster API can create the clusters, then you register them. Argo CD or Flux can sync Git **into the workload space**, and KubeStellar fans the result out. OCM is already the transport underneath.

**For this repo, run the lab before adopting it.** Adopt it for a real fleet only if the lab matches the job (label-based fan-out of native objects) and you accept three costs: a pre-1.0 API (`control.kubestellar.io/v1alpha1`), an agent on every workload cluster, and Sandbox maturity. Karmada is the stronger default when the requirement is scheduling or failover. Argo CD or Flux is the stronger default when Git already expresses per-cluster desired state and the fleet is small.

Upstream still has no maintainer-written “when to choose us” page. Tracking issue [#3795](https://github.com/kubestellar/kubestellar/issues/3795) was open and labeled stalled on 4 November 2026. Treat comparison tables that circulate in that issue as drafts. One claim in that issue is wrong and is corrected below: KubeStellar **does** install an agent on each workload cluster.

## The problem it is aimed at

Once you have more than one cluster, “kubectl apply” stops being an operation and becomes a loop. People grow fleets for reasons that are real and independent of any product:

- environments (dev, test, prod) that must not share a control plane
- teams or tenants that must not share a cluster
- data-residency and policy boundaries
- failure domains across regions or clouds
- hardware that only exists in some clusters (GPU, edge sites)
- clusters that are intermittently connected

The pain shows up as soon as the same application has to land on many of those clusters:

- drift, because each cluster was applied by hand or by a slightly different pipeline
- N copies of the manifests, or N Kustomize overlays, for differences that are a label and one string
- no inventory of which clusters should have received the object
- status that lives only on the spoke, so “is it healthy?” means logging into every cluster
- a developer workflow that changes the moment you leave a single cluster

KubeStellar’s bet is that this pain is **propagation**, not scheduling and not cluster construction. The developer keeps a single-cluster workflow. Platform staff label clusters and write one policy.

That bet is narrow, and that is useful. It tells you when the project is finished helping you.

## What it is

KubeStellar is a CNCF Sandbox project (Apache-2.0) for multi-cluster configuration. The v0.30.1 README describes it as a way to deploy across clusters while still using the Kubernetes objects you already have, with no wrapping in a custom application bundle.

Three words carry the design:

- A **space** is an API server with storage, and enough generic Kubernetes controllers to make that API server usable. It is not necessarily a cluster that runs application pods. A KubeFlex `ControlPlane` is a space. A normal Kubernetes cluster is also a space.
- A **Workload Definition Space (WDS)** is where people put application objects and KubeStellar policy.
- An **Inventory and Transport Space (ITS)** is where the fleet is registered and where objects are handed to the transport.

Workload Execution Clusters (**WECs**) are the real clusters where the pods run.

KubeFlex, a sibling project, creates and tracks the WDS and ITS as `ControlPlane` objects inside a hosting cluster. The hosting cluster is not where the application runs. It hosts the control planes.

## How a change moves

1. Someone applies a `Deployment` (or any other object) to the WDS, with kubectl, Helm, or Kustomize. The object is normal Kubernetes YAML.
2. A `BindingPolicy` in that same WDS has already selected the object (by labels, namespace, API group, resource, name) and selected clusters (by labels on their inventory objects). Order does not matter. The binding controller reconciles either change.
3. The controller writes a `Binding`. The `Binding` is the resolved list: these objects, these clusters. Read it when a policy “does nothing” — it shows what actually matched.
4. The transport controller, one per WDS, turns that into Open Cluster Management `ManifestWork` objects in per-cluster mailbox namespaces inside the ITS.
5. The OCM work agent on the WEC applies those objects. A status add-on agent reports status back into `WorkStatus` objects in the ITS.
6. The status controller can project that reported state into the WDS, if the policy asked for it.

Registration of a WEC is OCM’s double opt-in. The spoke asks to join, a certificate signing request appears on the hub, and a hub admin accepts the `ManagedCluster`. Both sides have to agree. KubeStellar does not hide this; the getting-started guide uses `clusteradm` directly.

```text
kubectl / Helm / Argo / Flux
        │
        ▼
Workload Definition Space          BindingPolicy, Binding, workload objects
        │
        │  transport controller wraps objects as ManifestWork
        ▼
Inventory and Transport Space      ManagedCluster inventory, mailbox namespaces
        │
        │  OCM work agent on each WEC pulls and applies
        ▼
Workload Execution Clusters        the clusters where pods actually run
        │
        └── status add-on reports WorkStatus back toward the WDS
```

There is an agent on every WEC: the OCM klusterlet (registration agent plus work agent) and the KubeStellar status add-on. A draft comparison that calls KubeStellar agentless does not match the architecture doc.

## Features that exist in v0.30

These are the behaviors documented for users, not a roadmap.

**Native objects.** The WDS stores `Deployment`, `Namespace`, Helm releases, and custom resources as themselves. You do not wrap them in a KubeStellar bundle. Helm is installed with `--kube-context` pointed at the WDS. Argo CD is the same idea: sync into the WDS, let policy fan out.

**Label placement.** `spec.clusterSelectors` is a list of label selectors against `ManagedCluster` objects in the ITS. A cluster matches if any selector matches. Workload selection is `spec.downsync`: a list of clauses with object label selectors, and optional filters for namespace, API group, resource, and name. An object matches a clause if it matches any of that clause’s object selectors.

**Resolved bindings as feedback.** `BindingPolicy` is what you write. `Binding` is what matched. You can skip the policy and maintain a `Binding` yourself, or let another controller do it.

**Per-cluster customization by template.** Annotate an object with `control.kubestellar.io/expand-templates: "true"`. Each leaf string is a Go `text/template`. Properties come from, in order: a `ConfigMap` named after the cluster in the ITS namespace `customization-properties`, then annotations on the `ManagedCluster` whose keys are Go identifiers, then labels of the same kind, then a built-in `clusterName`. Expansion errors are recorded on the `Binding` status, and a failure stops that binding from pushing a new desired state. Templates only rewrite strings that were already valid on the WDS, so this is substring replacement, not a second Kustomize.

**Field stripping.** On the way to a WEC, KubeStellar removes cluster-local metadata (`resourceVersion`, `uid`, `managedFields`, `status`, and similar) from every object. `Service` objects lose `clusterIP` unless it is `None`, and lose `nodePort` unless annotated `control.kubestellar.io/preserve=nodeport`. `Job` objects lose `spec.selector` and controller-uid labels, which is what makes a Job safe to copy.

**CustomTransform.** A `CustomTransform` in the WDS names an API group and resource and lists JSON paths to remove, for example `$.spec.suspend` on `batch/jobs`. It only removes fields. Changing a `CustomTransform` does not by itself push updates; the new rules are read the next time the object is propagated for some other reason. That limitation is still listed in the 0.29 release notes.

**Create-only.** A downsync clause can set `createOnly: true` so later edits in the WDS are not forced onto objects that already exist on the WEC. The documented example uses this for `Deployment` while still syncing `Namespace`.

**Status return.** `wantSingletonReportedState: true` on a downsync clause copies full status back onto the object in the WDS. The example scenarios still call this experimental, and it is defined for a single destination. v0.30.0 added `wantMultiWECReportedState` so status from many clusters can be aggregated, including Deployment status. Read [the multi-WEC status guide](https://github.com/kubestellar/docs/blob/main/docs/content/kubestellar/multi-wec-aggregated-status.md) before depending on the shape of that status.

**Out-of-tree resources.** A CRD can be propagated, or it can be installed on the WDS and the WECs by some other means. The OCM work agent’s service account does not automatically get permission to apply every CRD. The AppWrapper example adds a `ClusterRole` on each WEC by hand. Upstream issue [#1542](https://github.com/kubestellar/kubestellar/issues/1542) tracks automating that.

**Many spaces.** One hosting cluster can run multiple WDSes and multiple ITSes. A WDS or an ITS can be a KubeFlex control plane or the hosting cluster itself. The core Helm chart is how you ask for them. The chart can also install Argo CD; that is optional and not required to evaluate the core.

**What you do not get from core.** Cluster lifecycle, cross-cluster services, a service mesh, replica spreading, failover, and a stable v1 API. The web console and the MCP server are separate repositories. They are not required to judge the engine, and this evaluation does not treat them as part of the core contract.

## What you give up, or have to operate

These are the costs that should decide the evaluation, ahead of any feature list.

**Maturity.** Sandbox, version 0.30.1, API `v1alpha1`. Karmada graduated on 3 September 2026. OCM, which KubeStellar rides on for transport, moved to Incubating on 4 November 2026. A Sandbox project below 1.0 will change APIs. Budget for that, or do not put it on the production critical path yet.

**An agent per cluster, and a hosting cluster with TLS passthrough.** Every WEC runs klusterlet plus the status add-on. The hosting cluster must expose an ingress with SSL passthrough so those agents, and your `kubectl`, can reach the space API servers. A plain `kind create cluster` is not a hosting cluster. Upstream ships `create-kind-cluster-with-SSL-passthrough.sh` for the lab. On macOS, plan on Docker Desktop with at least 6 GB of memory for the three-cluster lab; the getting-started page says 8 GB machines should not run more than two or three kind clusters.

**Registration stays visible.** You approve CSRs and accept `ManagedCluster` objects. That is deliberate (both sides opt in). It is also operational work, and it is OCM’s workflow, which you will see in every install.

**Helm release secrets are not selected by Helm’s own labels.** `helm list` on a WEC stays empty unless you label the Helm metadata `Secret` so the policy picks it up. The workload still runs. Upstream issue [#1543](https://github.com/kubestellar/kubestellar/issues/1543) tracks doing this automatically.

**Limits called out for 0.29.0, which 0.30 did not advertise as fixed.** The published release notes through 0.29.0 still list:

- singleton status return fights a `Job` controller over `.status.replicas` while the Job is running
- deleting a `WorkStatus` in the transport namespace is not a supported way to get it recreated
- the same object identity (group, version, kind, namespace, name) on two WDSes is not detected as a conflict
- behavior is unspecified when two `Binding` objects both name one workload object and either says create
- raising the ManifestWork object-count limit above the default of 1 can delete and recreate objects on the WEC during a resplit, which defeats create-only

Confirm these against a 0.30.x release-notes page before you design around them. v0.30.0’s user-visible change was multi-WEC status, plus smaller controller and chart fixes. v0.30.1 is mostly dependency and CI updates.

**Local demo is not a production topology.** Upstream says so on the getting-started page. Production means a real hosting cluster (the docs also cover EKS and GKE paths), reachable ingress, and a plan for who accepts new clusters.

## How this repo boots it

`setup.sh` follows the upstream step-by-step for a single machine, pinned to **v0.30.1**, with one ITS (`its1`) and one WDS (`wds1`). The upstream quickstart also creates a second, host-type WDS. This lab does not, because the published example scenarios assume one WDS.

The script:

1. Runs upstream `check_pre_req.sh` for `kflex` (0.8.0 or newer), `ocm` (`clusteradm` **0.10.x**, install 0.10.1), `helm`, `kubectl`, `docker`, and `kind`. The prerequisites page says clusteradm 0.11 and later renamed a ServiceAccount and break this integration, even though newer OCM releases exist.
2. Refuses to start if `kubeflex`, `cluster1`, or `cluster2` already exist.
3. Creates the hosting cluster with the upstream SSL-passthrough script, on host port 9443.
4. Installs `oci://ghcr.io/kubestellar/kubestellar/core-chart` at 0.30.1.
5. Adds kubeconfig contexts `its1` and `wds1` with `kflex`.
6. Waits for the ITS post-create hooks `its-hub-init` and `install-status-addon`. Those names changed in 0.29; waiting on the older hook name hangs.
7. Creates two kind clusters, joins them with `clusteradm` using `--force-internal-endpoint-lookup` (correct when every cluster is on one host), waits for the CSRs, and accepts them.
8. Labels both `ManagedCluster` objects `location-group=edge`.
9. Applies `examples/nginx-binding-policy.yaml` and `examples/nginx-workload.yaml` to `wds1`, then waits until both WECs have `deployment/nginx-deployment` in namespace `nginx`.

`./teardown.sh` deletes the three kind clusters and the lab kubeconfig contexts.

After a successful run, the contexts you care about are:

| Context | What it is |
| --- | --- |
| `kind-kubeflex` | KubeFlex hosting cluster. Look here for `ControlPlane` objects and the controller Deployments. |
| `its1` | Inventory. `kubectl --context its1 get managedclusters`. |
| `wds1` | Where you apply workloads and `BindingPolicy` objects. |
| `cluster1`, `cluster2` | The WECs. Pods land here. |

A useful first inspection, once nginx is up:

```shell
kubectl --context wds1 get bindingpolicies,bindings
kubectl --context its1 get managedclusters --show-labels
kubectl --context cluster1 get deploy -n nginx
kubectl --context cluster2 get deploy -n nginx
```

Change the policy or the deployment on `wds1` only. Then look at the WECs again. That loop is the product.

## What to decide after the lab

Watch four things. They answer the adoption question better than a feature matrix.

1. **Time and moving parts.** Three clusters, an ingress, KubeFlex, two control planes, OCM hub, two agents per WEC. If the fleet is two or three clusters and Git already describes them, this is more system than the problem.
2. **The `Binding` object.** If the resolved object list and cluster list are the operational view you wanted, the abstraction is working. If you needed “run 10 replicas somewhere in this region, and move them when a cluster goes NotReady,” the `Binding` will look like the wrong object.
3. **Status.** See whether singleton or multi-WEC status on the WDS is enough to stop logging into spokes. If it is not, you still need a fleet observability stack, and KubeStellar did not remove that need.
4. **Day-2 edits.** Template expansion and `CustomTransform` cover string substitution and field removal. They do not cover a different chart, a different image per cluster, or structural overlays. Those remain Kustomize or Helm values, either before the object hits the WDS or as separate objects with tighter selectors.

If those four land well, a sensible next step is still not “replace the platform.” It is: point an existing GitOps controller at `wds1` for one non-production application, keep Cluster API (or whatever already creates clusters) in charge of lifecycle, and re-evaluate when the API leaves `v1alpha1` or the project leaves Sandbox.

## Sources

- [KubeStellar v0.30.1 README](https://github.com/kubestellar/kubestellar/blob/v0.30.1/README.md)
- [Releases](https://github.com/kubestellar/kubestellar/releases), including v0.30.0 (13 May 2026) and v0.30.1 (3 November 2026)
- [Architecture](https://github.com/kubestellar/docs/blob/main/docs/content/kubestellar/architecture.md)
- [Getting started](https://github.com/kubestellar/docs/blob/main/docs/content/kubestellar/get-started.md) (steps in this repo follow this page; the page’s script pins were v0.30.0 when checked)
- [Binding](https://github.com/kubestellar/docs/blob/main/docs/content/kubestellar/binding.md)
- [Transforming desired state](https://github.com/kubestellar/docs/blob/main/docs/content/kubestellar/transforming.md)
- [Example scenarios](https://github.com/kubestellar/docs/blob/main/docs/content/kubestellar/example-scenarios.md), scenario 1 is the nginx lab here
- [Release notes through 0.29.0](https://docs.kubestellar.io/release-0.29.0/direct/release-notes/) for the limitation list
- [Karmada CNCF project page](https://www.cncf.io/projects/karmada/) and [OCM CNCF project page](https://www.cncf.io/projects/open-cluster-management/) for maturity
- [Issue #3795](https://github.com/kubestellar/kubestellar/issues/3795), competitive positioning, open as of 4 November 2026
