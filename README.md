# Azure Container Apps POC

Proof of concept: a hello-world container served over HTTPS on a custom domain (`container.zure.jalcalaroot.com`), running on **Azure Container Apps** (Consumption plan — the Azure equivalent of ECS on Fargate, not ACI and not AKS), fronted by **Application Gateway** with a **Let's Encrypt** certificate, pulling its image from a dedicated **Azure Container Registry**, and monitored through **Azure Monitor** / Log Analytics.

This project builds on top of the network layer in the sibling [`azure-virtual-network`](../azure-virtual-network) project — it does not create its own VNet, it consumes two of that project's subnets.

## Architecture overview

```
                              Internet
                                 |
                    Application Gateway (snet-appgw)
                    - Public IP, TLS termination (Let's Encrypt via Key Vault)
                    - HTTP -> HTTPS redirect
                                 |
                    (VNet-internal traffic only, no public IP below this line)
                                 |
              Container Apps Environment (snet-containerapps)
              - internal_load_balancer_enabled = true
              - Workload profile: Consumption
                                 |
                          Container App
                          (nginx:alpine hello-world, pulled from ACR)
```

Application Gateway is the *only* public entry point. The Container Apps Environment is internal-only — see [Design notes](#design-notes) for why.

## What this deploys

| Resource | Notes |
|---|---|
| Resource Group | `rg-containerapps-poc` — own lifecycle, no `prevent_destroy` (disposable POC, unlike `azure-virtual-network`) |
| Azure Container Registry | Basic SKU, admin user disabled — pull is via managed identity |
| Container Apps Environment | Internal-only, workload profile `Consumption`, placed in `azure-virtual-network`'s `snet-containerapps` |
| Container App | `nginx:alpine` + custom `index.html`, pulled from the ACR above |
| Private DNS Zone (Container Apps default domain) | Wildcard `A` record + VNet link — required for Application Gateway to resolve the Container App's FQDN internally |
| Application Gateway | Standard_v2, public IP, HTTP->HTTPS redirect, backend pool pointing at the Container App |
| Public IP | Standard SKU, attached to Application Gateway |
| Key Vault | **Dedicated to this project** (not the one in `azure-virtual-network` — see [Design notes](#design-notes)), RBAC-authorized, public |
| Azure DNS Zone | `zure.jalcalaroot.com` (or whatever `dns_zone_name` is set to) + an `A` record for the `container` host |
| ACME registration + certificate | Let's Encrypt, via DNS-01 challenge against the Azure DNS Zone above |
| User Assigned Managed Identities | One for Container App -> ACR pull (`AcrPull`), one for Application Gateway -> Key Vault read (`Key Vault Secrets User`) |
| Diagnostic Settings | Container Apps Environment, Application Gateway, ACR — all forwarded to `azure-virtual-network`'s existing Log Analytics Workspace |

## Design notes

- **Container Apps, not ACI, not AKS.** ACI is a single container group with no orchestration (closer to a one-off `ecs run-task`); AKS is a Kubernetes cluster you manage yourself. Container Apps on the Consumption plan is the closest match to **ECS on Fargate** — serverless, no nodes to manage, scales to zero.
- **The Container Apps Environment is internal-only** (`internal_load_balancer_enabled = true`). Microsoft's own docs note that an *external* workload-profile environment routes inbound traffic through a Microsoft-managed public IP that **bypasses the subnet's NSG entirely** — that would make `nsg-containerapps` (in `azure-virtual-network`) pointless and would mean the Container App is technically reachable without going through Application Gateway at all. Internal-only means Application Gateway is the sole public entry point, full stop.
- **A dedicated Key Vault, not the one in `azure-virtual-network`.** That Key Vault has `public_network_access_enabled = false` (Private Endpoint only). Application Gateway *can* reach it fine (same VNet, via the Private Endpoint) — but **importing the ACME-issued certificate into it is a data-plane operation**, and a `terraform apply` running outside the VNet (e.g. your laptop) can't reach a Private-Endpoint-only Key Vault's data plane. Rather than forcing every apply of this project through the `azure-jumpbox-server`, this project has its own Key Vault: RBAC-authorized, public network access enabled, but locked down via Azure RBAC role assignments (not "anyone can read it" — just not gated by a subnet).
- **Let's Encrypt via DNS-01, not the App Service/Container Apps built-in managed certificate.** Neither Application Gateway nor a plain Azure DNS Zone has a "free managed cert" feature (that only exists on App Service and Front Door, and on Container Apps' own built-in ingress — none of which apply once Application Gateway is doing TLS termination). DNS-01 against the Azure DNS Zone is handled entirely by the `vancluever/acme` Terraform provider's `azuredns` challenge provider, which by default uses the same Azure CLI credentials (`az login`) already required for `azurerm` — no separate service principal needed for a POC where the person applying Terraform already has Contributor-or-better on the subscription.
- **RBAC propagation delay.** Azure role assignments can take a couple of minutes to actually take effect. `time_sleep.wait_for_kv_rbac` (90s) sits between the Key Vault role assignments and anything that reads/writes to the vault's data plane (the certificate import, Application Gateway) — without it, the first `apply` can fail with a 403 even though the role assignment already exists in state.
- **No `prevent_destroy` anywhere in this project**, unlike `azure-virtual-network`. This is disposable POC infrastructure by design.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5.0
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli), logged in via `az login`, with Contributor-or-better on the subscription (needed both for `azurerm` and for the ACME DNS-01 challenge against Azure DNS)
- [Docker](https://docs.docker.com/get-docker/), to build and push the hello-world image
- `azure-virtual-network` already applied — you need its `containerapps_subnet_id`, `appgw_subnet_id`, `vnet_id`, and `log_analytics_workspace_id` outputs
- Control over the parent domain (`jalcalaroot.com` or wherever `dns_zone_name` sits) to delegate NS records to the Azure DNS Zone this project creates — **do this before running `terraform apply`**, or the Let's Encrypt DNS-01 challenge will fail (Let's Encrypt's resolvers won't see the TXT record if the zone isn't authoritative yet)

## Usage

```bash
az login
export TF_VAR_subscription_id="<your-subscription-id>"
export TF_VAR_acme_email="you@example.com"

# From azure-virtual-network, after it's applied:
terraform output containerapps_subnet_id
terraform output appgw_subnet_id
terraform output vnet_id
terraform output log_analytics_workspace_id
```

Pass those four as `-var` (or put them in a gitignored `.tfvars`):

```bash
terraform init
terraform validate

terraform apply \
  -var "network_containerapps_subnet_id=<...>" \
  -var "network_appgw_subnet_id=<...>" \
  -var "network_vnet_id=<...>" \
  -var "network_log_analytics_workspace_id=<...>" \
  -target=azurerm_dns_zone.this
```

1. **Apply just the DNS zone first** (`-target` above) and read `terraform output dns_zone_name_servers`.
2. **Delegate those NS records** from the parent zone/registrar for `dns_zone_name`. Wait for propagation (`dig NS zure.jalcalaroot.com` should return Azure's name servers).
3. **Build and push the hello-world image** (the Container App can't come up without it already existing in ACR):
   ```bash
   ACR_LOGIN_SERVER=$(terraform output -raw acr_login_server)
   az acr login --name $(echo $ACR_LOGIN_SERVER | cut -d. -f1)
   docker build -t $ACR_LOGIN_SERVER/hello-world:latest ./docker
   docker push $ACR_LOGIN_SERVER/hello-world:latest
   ```
4. **Apply everything else**:
   ```bash
   terraform apply -var "network_containerapps_subnet_id=<...>" -var "network_appgw_subnet_id=<...>" -var "network_vnet_id=<...>" -var "network_log_analytics_workspace_id=<...>"
   ```
5. Visit `https://container.zure.jalcalaroot.com` (or whatever `dns_record_name`.`dns_zone_name` resolves to).

```bash
terraform destroy   # tear down - no lifecycle blocks to remove first, unlike azure-virtual-network
```

### Renewing the certificate

`acme_certificate` renews automatically on `terraform apply` once the certificate is within 30 days of expiry (`min_days_remaining` default) — but nothing runs `apply` on a schedule in this POC. Re-run `terraform apply` periodically (or wire this into a scheduled pipeline) to actually pick up the renewal.

### Let's Encrypt rate limits

`acme_server_url` defaults to Let's Encrypt **production**, which limits you to 5 duplicate certificates per domain per week. While iterating on this config, switch to the [staging environment](https://letsencrypt.org/docs/staging-environment/) (`https://acme-staging-v02.api.letsencrypt.org/directory`) to avoid burning through that limit on trial-and-error applies, and only point at production once things work end-to-end.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `subscription_id` | — | Azure subscription ID, via `TF_VAR_subscription_id` |
| `location` | `centralus` | Must match `azure-virtual-network`'s region |
| `resource_group_name` | `rg-containerapps-poc` | Own resource group |
| `network_containerapps_subnet_id` | — | From `azure-virtual-network` output |
| `network_appgw_subnet_id` | — | From `azure-virtual-network` output |
| `network_vnet_id` | — | From `azure-virtual-network` output |
| `network_log_analytics_workspace_id` | — | From `azure-virtual-network` output |
| `acr_name` | `acrcontainerappspoc` | Must be globally unique |
| `key_vault_name` | `kv-containerapps-poc` | Must be globally unique |
| `dns_zone_name` | `zure.jalcalaroot.com` | Must be delegated from the parent zone before apply |
| `dns_record_name` | `container` | Final FQDN = `<dns_record_name>.<dns_zone_name>` |
| `acme_email` | — | Let's Encrypt account email, via `TF_VAR_acme_email` |
| `acme_server_url` | Let's Encrypt production | Switch to staging while iterating |
| `container_image_tag` | `latest` | Must already exist in ACR before applying the Container App |
| `container_cpu` / `container_memory` | `0.25` / `0.5Gi` | Consumption plan minimum |
| `app_gateway_sku_capacity` | `1` | Fixed capacity, no autoscaling (POC) |

## Outputs

| Output | Description |
|---|---|
| `fqdn` | Final public hostname |
| `app_gateway_public_ip` | Application Gateway's public IP |
| `dns_zone_name_servers` | NS records to delegate from the parent zone |
| `acr_login_server` | For `docker build`/`push` |
| `container_app_environment_default_domain` / `container_app_fqdn` | Internal FQDNs (VNet-only resolution) |
| `key_vault_name` | This project's dedicated Key Vault |

## Relationship to `azure-virtual-network`

This project reads (copies, no `terraform_remote_state`) `containerapps_subnet_id`, `appgw_subnet_id`, `vnet_id`, and `log_analytics_workspace_id` from that project's outputs. It deliberately does **not** read `key_vault_id` — see [Design notes](#design-notes). If subnet CIDRs, names, or those outputs change over there, re-check this project before assuming it's unaffected.

## Cost considerations

Main ongoing costs: Application Gateway (hourly + capacity units), its Standard Public IP, Container Apps Consumption (per vCPU-second/GiB-second while running, scales toward zero when idle), Azure Container Registry (Basic SKU, flat monthly), Key Vault (per-operation, negligible at this scale), Azure DNS Zone (per-zone + per-query), Log Analytics ingestion (shared with `azure-virtual-network`, incremental cost only). Estimate with the [Azure Pricing Calculator](https://azure.microsoft.com/en-us/pricing/calculator/).

## Next steps

Not covered here: WAF on Application Gateway (currently `Standard_v2`, not `WAF_v2`), automated certificate renewal scheduling, autoscaling rules on the Container App beyond `min_replicas`/`max_replicas`, and multi-region.
