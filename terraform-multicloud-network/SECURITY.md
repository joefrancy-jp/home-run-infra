# Security and VPN operations

## Security boundaries

AWS security groups are in `modules/platform/aws/main.tf`: VPN, workers, EKS
control plane, public ALB, and a reusable database SG. The database SG is output
for database modules to attach; this repository does not yet create a database.
GCP firewall rules are in both network and platform modules. Azure NSGs are in
`modules/platform/azure/main.tf` and are attached to private/database subnets,
the dedicated Application Gateway subnet, and the VPN NIC.

Internal VPC traffic is allowed at the cloud network layer as requested. The
public LB reaches only the private gateway on TCP 8000. Worker/API endpoints have
no public ingress, and workers have no public IP. Cloud health checks and managed
control-plane traffic have explicit exceptions. Application namespaces enforce
ClusterIP-only Services, private ingress classes, and no independent Gateway
objects through admission policies. Namespace network policies isolate Dev/QA
and allow the shared gateway and Linkerd control plane. Give application teams
namespace-scoped RBAC; they must not change namespace labels, cluster policies,
or platform ingress/controller resources.

Linkerd's application default is authenticated mesh traffic. Connecting to the
VPN does not bypass application authentication or Kubernetes RBAC. ClusterIP
addresses are not generally routable from a laptop; use authenticated
`kubectl port-forward` or a deliberately configured private ingress for app
administration. The VPN provides private network reachability, not cluster-admin
rights or a universal cloud identity.

OpenVPN is the intentional public administration exception: UDP 1194 accepts
connections from any laptop, but only a valid, non-revoked client certificate
can establish a tunnel. Optional `vpn_source_cidrs` can narrow the source ranges.
It is not a rule allowing the public internet into the VPC CIDR. Public SSH,
OpenVPN Access Server ports 943/443, and public ICMP are not opened.

## Prerequisites

Create state storage, configure OIDC and approvals, enable the relevant GCP APIs
and Azure resource providers, and check regional Kubernetes/VM quotas. GCP planning
needs Compute API enabled to discover zones; the stack also manages required
container/IAM/IAP/OS Login service enablement. Pin `kubernetes_version` to a
supported cloud version for controlled upgrades; null follows the cloud default
(GKE uses REGULAR). The Kubernetes chart requires version 1.30 or newer.

Each Terraform root needs `cluster_admin_identities`; AWS/Azure also need an
administrator SSH public key. AKS expects an RSA key (2048 bits or greater).
Set these through the documented GitHub variables or a local ignored
`ci.auto.tfvars.json`. Plan identities need read access to the new Kubernetes,
compute, IAM and firewall resources. Apply identities need provisioning, IAM
binding/role assignment, service enablement, and state permissions. The private
runner identity must also be one of the effective Kubernetes administrators.

AWS management of the VPN VM uses SSM; grant operators permission to start SSM
sessions. GCP bootstrap grants the configured administrators IAP tunnel access,
OS Admin Login on the VPN VM, and use of its otherwise unprivileged service
account. Azure operators need VM Run Command permission for bootstrap and the
cluster's Entra group membership for Kubernetes. No cloud credentials or generated
private keys are embedded into VM startup data.

## Issue and revoke VPN profiles

The shared Ubuntu startup script installs OpenVPN Community Edition, EasyRSA,
dnsmasq, and persistent forwarding/NAT rules from distribution packages. It
creates the CA/server private keys on the VM only. No unpinned installer is
downloaded and executed, and Terraform never holds VPN private keys.

Wait for cloud-init/startup completion, then open an administrative session:

- AWS: SSM Session Manager to the output `vpn_instance_id`.
- GCP: `gcloud compute ssh <vpn_instance_id> --zone <vpn_zone> --tunnel-through-iap`.
- Azure: VM Run Command, or private SSH after a first profile has been issued.

On the VM, issue one profile per person/device:

```sh
sudo /usr/local/sbin/vpn-client issue alice-laptop
sudo systemctl status openvpn-server@server
```

The profile is `/root/vpn-clients/alice-laptop.ovpn`. Transfer it securely using
an administrator-authorized channel and import it into the laptop's OpenVPN
client. Do not put profiles into GitHub artifacts, workflow output, commits, or
shared chat. Each profile includes a private key and is a bearer credential.
Do not share one profile among multiple users. Azure Run Command can invoke the
issuance helper noninteractively; keep profile retrieval out of shared logs.

To revoke a device:

```sh
sudo /usr/local/sbin/vpn-client revoke alice-laptop
```

Revocation updates the CRL and restarts the VPN service, disconnecting all current
sessions; other valid clients can reconnect. A daily systemd timer refreshes the
CRL; monitor timer health and certificate expiry. Back up CA/server material encrypted
under restricted access if clients must survive VM replacement. AWS user-data or
Azure custom-data changes may replace the VM and require reissuing profiles.
GCP startup reruns preserve an existing CA. Destroying UAT intentionally removes
its VPN material; recreate profiles on its next creation.

The VPN pushes private VPC routes (and GKE pod/control-plane routes) and a DNS
resolver on the tunnel. VPN-to-private traffic is SNATed to the VM's private IP,
so no client-subnet return routes are needed. DNS is forwarded to the cloud VPC
resolver, including private Kubernetes API names. The VPN is split tunnel and
does not provide an internet exit. Enable the OpenVPN client's DNS integration
on Linux if its client does not automatically install pushed DNS settings.

The requested single VPN VM is not HA. Its failure interrupts administrator
access but does not remove the managed HA control plane or application LB.

## Linkerd and public ingress

Use the **Private cluster add-ons** workflow after Terraform finishes, or run
`bash terraform-multicloud-network/kubernetes/manage.sh install platform.json routes.yaml`
from the repository root while connected to the VPN.
Obtain the config with `terraform output -json platform > platform.json` in the
chosen root. The script always creates a temporary kubeconfig for that exact
cluster and checks connectivity before installing anything.

Linkerd charts are pinned to upstream open-source edge version `2026.9.3`; the
AWS controller chart and IAM policy are pinned to `3.5.0`. Linkerd control-plane
replicas, disruption budgets, and pod anti-affinity are configured for HA. GKE
uses Calico network policies with the legacy datapath to preserve the ClusterIP
service discovery Linkerd needs, and owns its Gateway API CRDs. Other clusters
install the route CRDs through Linkerd's chart.

Supply a valid trust anchor, signed CA issuer certificate/private key, ingress
hostname, and an issued public TLS certificate. Keep CA root private keys offline;
only the signed issuer key belongs in the protected deployment secrets. The
installer checks issuer chain, key matching, and expiry, but certificate renewal
is not automated here. Schedule issuer/webhook rotation before expiry. Follow
[Linkerd certificate rotation](https://linkerd.io/docs/tasks/manually-rotating-control-plane-tls-credentials/).

AWS uses ACM in the cluster region. GCP/Azure use the Kubernetes `gateway-tls`
Secret, which their controllers consume. Configure the seven actual services
and paths in `terraform-multicloud-network/kubernetes/environments/<env>/routes.yaml` and create matching
ClusterIP Services/Deployments in their application repositories. Paths are
forwarded unchanged. No sample application is published by default. Update DNS
to the resulting LB. There is no port 80 listener permitted by the cloud rules.

Traefik here supplies routing, not a complete API-management product. Add your
application's JWT/authentication, rate limits, and API policies separately. The
LB-to-gateway hop is private HTTP; Linkerd encrypts gateway-to-meshed-service
traffic. If policy requires encrypted LB-to-gateway transport too, configure
backend TLS for the relevant cloud controller before production deployment.

## UAT teardown and verification

UAT create/destroy and cluster add-on installation are approval-gated. UAT
teardown needs the VPN-connected `private-cluster` runner to live outside UAT.
It removes the platform chart/namespaces while controllers still run, waits for
LB deletion, then removes Linkerd/controllers and applies the saved Terraform
destroy plan. Do not manually remove the VPN or cluster first. Independently
managed public Ingresses/LBs, retained disks, snapshots, and other Helm releases
must be reviewed before destruction. Production GKE deletion protection is on.

After an actual deployment, verify from outside the VPN that only HTTPS and the
VPN listener are reachable, then connect the VPN and verify private SSH/API
access with a non-admin and admin identity. Run Linkerd checks, test inter-service
mTLS and Dev/QA isolation, deny-test a public Service in an app namespace, and
exercise node/zone disruption and UAT teardown. Local validation and mock-provider
tests do not establish live cloud reachability, quotas, runtime permissions,
OpenVPN boot success, or load-test performance.

References: [Linkerd ingress](https://linkerd.io/docs/features/ingress/),
[private GKE Linkerd configuration](https://linkerd.io/docs/reference/cluster-configuration/),
[OpenVPN 2.6](https://openvpn.net/community-docs/community-articles/openvpn-2-6-manual.html),
[GKE Gateway](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/deploying-gateways),
[AKS AGIC](https://learn.microsoft.com/en-us/azure/application-gateway/ingress-controller-overview).
