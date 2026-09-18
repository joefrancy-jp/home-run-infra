# Private multi-cloud platform

```text
terraform-multicloud-network/
  environments/
    dev/network/{aws,gcp,azure}/    # Persistent Dev/QA
    uat/network/{aws,gcp,azure}/    # On-demand load testing
    prod/network/{aws,gcp,azure}/   # Production
  modules/network/{aws,gcp,azure}/ # Networks, subnets, NAT
  modules/platform/{aws,gcp,azure}/# Private clusters, firewall/SG/NSG, VPN VMs
  modules/platform/openvpn-bootstrap.sh.tftpl
  kubernetes/
    platform/                     # Meshed gateway, cloud LB bindings, policies
    environments/{dev,uat,prod}/   # Real application routes
    manage.sh                     # Run through VPN, never expose the cluster API
```

Each environment/cloud root keeps its existing state name and now owns its network,
cluster, and OpenVPN VM. The LB is reconciled by Kubernetes controllers after
the cluster exists. Infrastructure and in-cluster changes have separate approval
gates because the Kubernetes API is deliberately private.

| Cloud | Private control plane / workers | Public application entry point |
| --- | --- | --- |
| AWS | EKS managed multi-AZ control plane; private endpoint; worker subnets in 3 AZs | AWS Load Balancer Controller, HTTPS ALB |
| GCP | Regional GKE control plane; private nodes/endpoint; workers in 3 zones | GKE Gateway controller, regional external Application Load Balancer |
| Azure | Private AKS, Standard SLA tier, 3-zone node pool | Managed AGIC and Application Gateway |

Linkerd supplies internal mTLS and service-to-service load balancing; it does not
provision cloud load balancers. A three-replica Traefik gateway receives LB traffic
and forwards it to the meshed ClusterIP services. Application authentication,
authorization, quotas, and business APIs remain application responsibilities.

Customer path: HTTPS LB -> private gateway pods -> Linkerd -> private services.
Administrator path: certificate-authenticated OpenVPN -> private VM/Kubernetes
endpoints, with SSH keys and IAM/RBAC still required.

Public application traffic is accepted on TCP 443 only. UDP 1194 is the separate
VPN entry point. There is no internet-wide SSH rule. GCP permits IAM-authorized
IAP SSH to the VPN VM only for initial administration. Other provider management
and health-check exceptions are explicitly restricted by source/target rules.
Outbound NAT remains available for updates, images, and cloud APIs.

Dev and QA share a cluster with separate namespaces and network policies. UAT is
a separate stack and only created on demand; production is separate. Current
dev/prod VPC CIDRs overlap across isolated networks. Redesign address ranges before
peering networks or using concurrent VPN connections across clouds/environments.
Use separate production accounts/projects/subscriptions where possible.

Start with [CI setup](../.github/README.md) and the [security and VPN runbook](SECURITY.md).
No cloud deployment is performed merely by adding these files.

Sources: [EKS architecture](https://docs.aws.amazon.com/eks/latest/userguide/eks-architecture.html),
[GKE network isolation](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/network-isolation),
[private AKS](https://learn.microsoft.com/en-us/azure/aks/private-clusters),
[Linkerd ingress](https://linkerd.io/docs/features/ingress/).
