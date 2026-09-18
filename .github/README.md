# Infrastructure workflows

## Folder-driven plans

Terraform roots are `terraform-multicloud-network/environments/<dev|uat|prod>/network/<cloud>`.
`dev` owns shared Dev/QA infrastructure with separate Kubernetes namespaces.
`uat` is isolated and created on demand for load testing. `prod` owns production.
These roots now create the network, private Kubernetes cluster, security rules,
and OpenVPN VM together. Kubernetes controllers create the application LB in a
second, approval-gated **Private cluster add-ons** workflow.

AWS and GCP are enabled by default. Set repository variable `TF_ENABLED_CLOUDS`
to a JSON array such as `["gcp"]` or `["aws","gcp","azure"]` to select the clouds
you operate. Manual plans can target any supported cloud.

| Change | Automatic targets |
| --- | --- |
| `environments/dev/network/gcp/**` | GCP dev |
| `environments/prod/network/aws/**` | AWS prod |
| `environments/uat/network/gcp/**` | GCP UAT plan only, including after merge |
| `modules/network/gcp/**` | GCP dev and prod |
| `modules/platform/gcp/**` | GCP dev and prod |
| Shared OpenVPN bootstrap | All enabled clouds, dev and prod |
| Shared workflows/actions/scripts or `deploy.sh` | All enabled clouds, dev and prod |
| Documentation only | Secret scan only |

Shared changes select dev/prod only and cannot create UAT. Explicit UAT folder
changes get a plan but never automatically apply. Before creating UAT, its manual
workflow always plans the latest selected commit, including shared module changes.

## On-demand UAT

Use **Actions -> UAT on demand -> Run workflow**, selecting `main` or `master`,
the cloud, and an operation:

- `plan`: preview only.
- `create`: plan creation/update, review the artifact, then approve deployment.
- `destroy`: plan destruction, review the artifact, then approve teardown.

Create `terraform-<cloud>-uat-plan` and `terraform-<cloud>-uat-apply` with the same
OIDC, backend, variable, and required-reviewer setup described below. The apply
identity needs deletion permissions for teardown. Both creation and destruction
require manual deployment approval. Keep changes reviewed/merged before starting
UAT. There is no scheduled creation or automatic deletion.

UAT has independent names and state: `network/uat-home-run-<cloud>.tfstate`
(GCP prefix `network/uat-home-run-gcp`), and uses `172.18.0.0/16` instead of the
dev/prod network range. Reuse the same UAT backend when recreating or destroying;
do not delete the state bucket/container. Destroy runs on a VPN-connected runner
labelled `private-cluster`, removes the platform Helm release and its namespaces
first, waits for LB finalizers, then removes Linkerd/controllers and applies the
saved Terraform destruction plan. The runner must live outside the UAT stack it
destroys. Retained application disks/snapshots or independently created LBs still
need explicit ownership/cleanup; review those before teardown.

PRs opened, updated, reopened, or marked ready against `main` or `master` run
TruffleHog and plan affected roots. No apply runs while the PR is open. Fork PRs
fail before cloud access; a maintainer must review and reproduce the change on a
trusted repository branch. Terraform executes code, so only trusted contributors
should have access to credentialed plan environments.

After an approved PR is merged:

1. Verify approval of the latest PR head by another repository collaborator,
   with no outstanding change requests. Closing without merging does nothing.
2. Verify required reviewers, prevent self-review, and disabled administrator
   bypass on each apply environment. Missing/unreadable protection fails closed.
3. Check out the exact merged commit and generate a fresh plan against remote
   state. The PR plan is a preview and is never used for apply.
4. Save the binary plan, readable `plan.txt`, and provider lockfile as an artifact.
5. Wait for manual deployment approval. Review `plan.txt` before approving.
   PR approval and deployment approval are separate.
6. Authenticate with the apply identity and apply that saved plan.

Direct pushes do not trigger apply. The main workflow's manual dispatch is
plan-only; the separate UAT workflow permits approved create/destroy. A deployment
whose branch has advanced is rejected before cloud authentication; merge a fresh
reviewed infrastructure PR to plan the latest version. If a run fails or its
artifact expires, rerun the whole workflow while its merged commit is current,
not only a failed job. Plans may contain sensitive values and expire in three days.
Per-state deployment concurrency and backend locks prevent simultaneous applies;
GitHub may replace an older pending run with a newer pending run.

## Required GitHub setup

Protect `main`/`master`: require PRs, at least one approval, dismiss stale approvals,
require **Terraform checks**, and disallow bypass/direct pushes. Review workflow
changes carefully. The workflow checks approval after merge but cannot prevent
an unapproved merge itself.

Create plan/apply environment pairs for every enabled target, for example
`terraform-gcp-dev-plan`, `terraform-gcp-dev-apply`, `terraform-gcp-prod-plan`,
and `terraform-gcp-prod-apply`, with equivalent names for AWS/Azure.

On every apply environment, configure **Required reviewers**, enable **Prevent
self-review**, and disable **Allow administrators to bypass configured protection
rules**. Permit only `main`/`master` as appropriate. Plan environments must also
permit `refs/pull/*/merge`; restricting them to only `main` blocks PR plans.
Environment protection evaluates the execution ref, not the source branch name.

Add repository secret `ENVIRONMENT_READ_TOKEN`: a fine-grained GitHub token scoped
to this repository with **Administration: read**, used to inspect protection.
The normal workflow token lacks this permission. An administrator must configure
reviewers and branch protection; workflow YAML cannot create those settings.

Configure cloud OIDC trust for the exact repository and environment subjects,
e.g. `repo:JoeFrancy1994/home-run-infra:environment:terraform-gcp-dev-plan`.
Use different plan/apply identities. Plan needs resource read and state read/lock
permissions; apply needs provisioning and state write permissions. Do not give
the plan identity infrastructure write access or trust it as the apply identity.

Set these variables on each GitHub environment. Keep the account/project,
location, and backend identical between a plan/apply pair; only identities differ.

| Cloud | Required variables |
| --- | --- |
| AWS | `AWS_ROLE_ARN`, `AWS_ACCOUNT_ID`, `AWS_REGION`, `TF_STATE_BUCKET` |
| GCP | `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT`, `GCP_PROJECT_ID`, `GCP_REGION`, `TF_STATE_BUCKET` |
| Azure | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_LOCATION`, `TF_STATE_RESOURCE_GROUP`, `TF_STATE_STORAGE_ACCOUNT`, `TF_STATE_CONTAINER` |

Every target also needs `CLUSTER_ADMIN_IDENTITIES`: a JSON array of IAM role ARNs
for AWS, IAM members (e.g. `group:admins@example.com`) for GCP, or Entra group
object IDs for Azure. AWS/Azure need `VPN_SSH_PUBLIC_KEY`; use an RSA public key
for AKS compatibility. Do not store its private key in Terraform or repository
variables. Add-ons/teardown identities must have Kubernetes administrator access
as well as cloud permissions; a VPN connection alone does not grant RBAC rights.

## Private cluster add-ons

After infrastructure apply, connect a dedicated self-hosted Linux runner to the
target VPC using its issued VPN profile. Label it `private-cluster`. Keep the
runner outside application clusters and restrict its runner group to trusted
deployment workflows, never untrusted PR jobs. It needs bash, jq, OpenSSL, Helm,
kubectl, AWS CLI, gcloud with the GKE auth plugin, Azure CLI, and kubelogin.
With one shared runner, connect it to the selected environment before dispatch;
overlapping VPC CIDRs prevent simultaneous connections without an address redesign.

Run **Private cluster add-ons** on `main`/`master` after reviewing/merging changes.
It uses the same protected apply environment and mandatory approval policy. Set:

- Variable `INGRESS_HOST` and, for AWS, `AWS_ACM_CERTIFICATE_ARN`.
- Secrets `LINKERD_TRUST_ANCHORS_PEM`, `LINKERD_ISSUER_CERT_PEM`, and
  `LINKERD_ISSUER_KEY_PEM` (a signed CA issuer for `identity.linkerd.cluster.local`).
- For GCP/Azure, secrets `INGRESS_TLS_CERT_PEM` and `INGRESS_TLS_KEY_PEM`.

Configure real services in `terraform-multicloud-network/kubernetes/environments/<environment>/routes.yaml`.
Empty routes deliberately return 404, not a sample public application. The
application repositories still own the seven service Deployments and ClusterIP
Services. See [the security runbook](../terraform-multicloud-network/SECURITY.md)
for VPN client issuance, identity rotation, required cloud permissions, and checks.

Create state storage first. CI overrides backend placeholders using these values;
local `deploy.sh` still needs its backend placeholders configured. State names
are preserved: `network/<dev|uat|prod>-home-run-<cloud>.tfstate` for AWS/Azure and
GCP prefix `network/<dev|uat|prod>-home-run-gcp`. Directory moves do not change resource
addresses. Do not change an existing backend/account without state migration.
Existing stage/QA/UAT state, if any, needs separate assessment; it is not merged
into dev automatically.

The job summary identifies the cloud, environment, account/project/subscription,
location, and state path. Infrastructure plans/creates use GitHub-hosted Ubuntu;
add-ons and UAT teardown use the VPN-connected self-hosted runner.

## Local checks

```sh
node --test .github/scripts/terraform-targets.test.cjs
actionlint .github/workflows/*.yml
cd terraform-multicloud-network
bash deploy.sh network gcp dev plan
```

Local Terraform must be at least 1.10; CI uses 1.10.5. Local `apply`/`destroy`
remain operator commands; GitHub approvals gate only the CI workflow.

References: [environment protection](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments),
[environment API permissions](https://docs.github.com/en/rest/deployments/environments#get-an-environment),
[PR environment refs](https://github.blog/changelog/2025-11-07-actions-pull_request_target-and-environment-branch-protections-changes/).
