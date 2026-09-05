# Azure Container Apps POC

A hello-world container served over HTTPS on a custom domain, running on **Azure Container Apps** (Consumption plan) behind **Application Gateway** with a **Let's Encrypt** certificate.

**Live:** https://container.azure.jalcalaroot.com

## Architecture

```
                              Internet
                                 |
                    Application Gateway (public)
                    TLS termination + HTTP -> HTTPS redirect
                                 |
                    ───── VNet-internal only below this line ─────
                                 |
              Container Apps Environment (internal, Consumption)
                                 |
                    Container App (nginx:alpine hello-world)
```

Application Gateway is the only public entry point. The Container Apps Environment has no public exposure — see [CLAUDE.md](CLAUDE.md) for the reasoning and other implementation gotchas.

This project consumes an existing VNet (subnets + Log Analytics Workspace) provisioned by a sibling network project; it does not create its own virtual network.

## Resources deployed

| Resource | Purpose | Docs |
|---|---|---|
| Resource Group | Container for everything below, own lifecycle | [Manage resource groups](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resource-groups-portal) |
| Azure Container Registry (Basic) | Hosts the `hello-world` image; admin user disabled | [ACR overview](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-intro) |
| Container Apps Environment | Internal-only boundary the Container App runs in (Consumption workload profile) | [Container Apps environments](https://learn.microsoft.com/en-us/azure/container-apps/environment) |
| Container App | The workload itself — `nginx:alpine` + a static `index.html` | [Container Apps overview](https://learn.microsoft.com/en-us/azure/container-apps/overview) |
| Private DNS Zone | Resolves the Container App's FQDN inside the VNet (required for an internal environment) | [Azure Private DNS](https://learn.microsoft.com/en-us/azure/dns/private-dns-overview) |
| Application Gateway (Standard_v2) | Public entry point: TLS termination, HTTP→HTTPS redirect, reverse proxy to the Container App | [Application Gateway overview](https://learn.microsoft.com/en-us/azure/application-gateway/overview) |
| Public IP (Standard) | Attached to Application Gateway | [Public IP addresses](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/public-ip-addresses) |
| Key Vault | Stores the TLS certificate; RBAC-authorized | [Key Vault overview](https://learn.microsoft.com/en-us/azure/key-vault/general/overview) |
| Key Vault certificate + Application Gateway integration | How App Gateway pulls the cert from Key Vault | [TLS termination with Key Vault certificates](https://learn.microsoft.com/en-us/azure/application-gateway/key-vault-certs) |
| Azure DNS Zone (existing, not created here) | Hosts the `A` record for the public hostname | [Azure DNS overview](https://learn.microsoft.com/en-us/azure/dns/dns-overview) |
| Let's Encrypt certificate (via ACME DNS-01) | The actual TLS certificate, issued through the [`vancluever/acme`](https://registry.terraform.io/providers/vancluever/acme/latest/docs) Terraform provider | [Let's Encrypt](https://letsencrypt.org/how-it-works/) |
| User Assigned Managed Identities (x2) | One for Container App → ACR pull, one for Application Gateway → Key Vault read | [Managed identities overview](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview) |
| Diagnostic Settings | Forwards logs/metrics from the environment, App Gateway, and ACR to an existing Log Analytics Workspace | [Diagnostic settings](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings) |

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5.0
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli), logged in via `az login` with Contributor-or-better on the subscription
- [Docker](https://docs.docker.com/get-docker/)
- The network project applied first — you need its subnet IDs, VNet ID, and Log Analytics Workspace ID (see [Configuration](#configuration))
- An existing, already-delegated Azure DNS Zone for your domain

## Usage

```bash
az login
export TF_VAR_subscription_id="<subscription-id>"
export TF_VAR_acme_email="you@example.com"

terraform init
terraform plan -out=tfplan \
  -var "network_containerapps_subnet_id=<...>" \
  -var "network_appgw_subnet_id=<...>" \
  -var "network_vnet_id=<...>" \
  -var "network_log_analytics_workspace_id=<...>"
```

1. **Create the registry first**, then build and push the image (the Container App can't be created without it):
   ```bash
   terraform apply -target=azurerm_container_registry.this <same -var flags as above>

   ACR=$(terraform output -raw acr_login_server)
   az acr login --name "${ACR%%.*}"
   docker build -t "$ACR/hello-world:latest" ./docker
   docker push "$ACR/hello-world:latest"
   ```
2. **Apply everything else:**
   ```bash
   terraform apply <same -var flags as above>
   ```
3. Visit the hostname printed in the `fqdn` output.

```bash
terraform destroy   # tear down, no lifecycle blocks to remove first
```

Renewing the certificate and Let's Encrypt rate limits: see [CLAUDE.md](CLAUDE.md).

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `subscription_id` | — | via `TF_VAR_subscription_id` |
| `acme_email` | — | via `TF_VAR_acme_email` |
| `location` | `eastus` | must match the VNet's region |
| `resource_group_name` | `rg-containerapps-poc` | |
| `network_containerapps_subnet_id` | — | from the network project |
| `network_appgw_subnet_id` | — | from the network project |
| `network_vnet_id` | — | from the network project |
| `network_log_analytics_workspace_id` | — | from the network project |
| `acr_name` | `acrcontainerappspoc` | globally unique |
| `key_vault_name` | `kv-jalcalaroot-capoc` | globally unique |
| `dns_zone_name` | `azure.jalcalaroot.com` | must already exist |
| `dns_zone_resource_group_name` | `jalcalaroot` | resource group of that zone |
| `dns_record_name` | `container` | final FQDN = `<dns_record_name>.<dns_zone_name>` |
| `acme_server_url` | Let's Encrypt production | use staging while iterating |
| `container_image_tag` | `latest` | must already exist in ACR before applying |
| `container_cpu` / `container_memory` | `0.25` / `0.5Gi` | Consumption plan minimum |
| `app_gateway_sku_capacity` | `1` | fixed, no autoscaling |

## Outputs

| Output | Description |
|---|---|
| `fqdn` | Public hostname |
| `app_gateway_public_ip` | Application Gateway's public IP |
| `acr_login_server` | For `docker build`/`push` |
| `container_app_environment_default_domain` / `container_app_fqdn` | Internal FQDNs (VNet-only resolution) |
| `key_vault_name` | This project's Key Vault |

## Cost

Main ongoing costs: Application Gateway (hourly + capacity units) and its Public IP, Container Apps Consumption (scales toward zero when idle), ACR Basic (flat monthly), Key Vault (per-operation), DNS queries, incremental Log Analytics ingestion. Estimate with the [Azure Pricing Calculator](https://azure.microsoft.com/en-us/pricing/calculator/).

## Not covered

WAF on Application Gateway (currently `Standard_v2`, not `WAF_v2`), scheduled certificate renewal, autoscaling beyond `min_replicas`/`max_replicas`, multi-region.
