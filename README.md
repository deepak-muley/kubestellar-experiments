# KubeStellar experiments

Evaluation lab for [KubeStellar](https://github.com/kubestellar/kubestellar) v0.30.1: what it is, the problem it actually solves, and a local bootstrap so you can decide whether to use it.

**Read first:** [docs/knowledge-base.md](docs/knowledge-base.md)

KubeStellar copies ordinary Kubernetes objects from one API (a Workload Definition Space) onto many clusters selected by labels. It sits on Open Cluster Management for transport. It does not create clusters, spread replicas, or fail over when a cluster dies. It is a CNCF Sandbox project and the control API is `v1alpha1`.

Use it when the job is “the same objects, many clusters.” Use Karmada when the job is scheduling and failover. Use Argo CD or Flux when Git already describes each cluster and the fleet is small. Use Cluster API when the job is creating the clusters.

## Lab

Needs Docker, kind, kubectl, Helm, the KubeFlex CLI (`kflex`) 0.8.0 or newer, and the OCM CLI (`clusteradm`) **0.10.1**. Upstream says clusteradm 0.11 and later break KubeStellar’s OCM integration, so do not install “latest.” On a Mac, give Docker Desktop at least 6 GB. The script checks versions with upstream `check_pre_req.sh` before it creates anything.

```shell
brew tap kubestellar/kubeflex https://github.com/kubestellar/kubeflex
brew install kubeflex

bash <(curl -fsSL https://raw.githubusercontent.com/open-cluster-management-io/clusteradm/main/install.sh) 0.10.1
```

`clusteradm` lands in `/usr/local/bin` and the installer asks for root. This machine already has Docker, kind, kubectl, and Helm. `kflex` and `clusteradm` are not on `PATH` yet.

```shell
./setup.sh
./teardown.sh
```

`setup.sh` builds one hosting cluster plus two workload clusters, registers them, and applies `examples/` so both clusters run nginx. Apply further changes to context `wds1` only.

| Context | Role |
| --- | --- |
| `kind-kubeflex` | Hosting cluster |
| `its1` | Cluster inventory |
| `wds1` | Where you apply workloads and BindingPolicies |
| `cluster1`, `cluster2` | Where the pods run |

## Console demo

The [console](https://github.com/kubestellar/console) is separate from the core lab. Demo mode is local sign-in with no GitHub OAuth, which is the quick start from the console repo. `kc-agent` is pointed at kind clusters that are actually running.

```shell
./console.sh setup
./console.sh run       # http://localhost:8080
./console.sh status
./console.sh stop
./console.sh destroy   # deletes only the kc-demo cluster
```

## Sources

- https://github.com/kubestellar/kubestellar
- https://github.com/kubestellar/kubeflex
- https://github.com/kubestellar/docs
