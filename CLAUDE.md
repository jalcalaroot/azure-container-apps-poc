# azure-container-apps-poc

POC: hello-world container on Azure Container Apps (Consumption plan — the ECS-Fargate equivalent, not ACI, not AKS), behind Application Gateway with a Let's Encrypt cert, image in a dedicated ACR, monitored via the Log Analytics Workspace already created by `azure-virtual-network`.

## Design decisions worth knowing before changing anything

- **Container Apps Environment is internal-only** (`internal_load_balancer_enabled = true`). An *external* workload-profile environment routes inbound traffic through a Microsoft-managed public IP that bypasses the subnet's NSG entirely — internal-only is what makes Application Gateway the actual sole entry point, and what makes `nsg-containerapps` (in `azure-virtual-network`) meaningful at all. Don't flip this to external without also reconsidering whether the NSG design still holds.
- **This project has its own Key Vault** (`kv-containerapps-poc`), separate from `azure-virtual-network`'s. That project's Key Vault is Private-Endpoint-only (`public_network_access_enabled = false`); importing an ACME certificate into a Key Vault is a *data-plane* operation, and a `terraform apply` run from outside the VNet (e.g. a laptop) can't reach a Private-Endpoint-only vault's data plane. Rather than requiring every apply to go through `azure-jumpbox-server`, this vault is RBAC-authorized and public (locked down by role assignment, not by network ACL).
- **No `prevent_destroy` anywhere.** Unlike `azure-virtual-network`, this is disposable POC infra by design — `terraform destroy` should just work.
- **DNS zone must be delegated before first apply.** Azure DNS Zone existing in Terraform state doesn't make it authoritative — the parent zone/registrar for `dns_zone_name` needs its NS records pointed at Azure DNS's assigned name servers first, or the Let's Encrypt DNS-01 challenge can't see the TXT record and issuance fails. Apply the DNS zone alone first (`-target=azurerm_dns_zone.this`), delegate, wait for propagation, then apply everything else.
- **RBAC propagation lag.** `time_sleep.wait_for_kv_rbac` (90s) exists because Azure role assignments can take a couple of minutes to actually take effect — without it, the first apply touching the Key Vault's data plane (cert import, or Application Gateway reading the cert) can 403 even though the role assignment already shows up in state. If you see a transient 403 on a fresh apply, this is why — don't "fix" it by removing the sleep, `terraform apply` again instead.
- **The image must already exist in ACR before the Container App is created/updated.** There's no Terraform resource that builds/pushes images. Build and `docker push` the `docker/` image to ACR before applying `container_apps.tf`, using `az acr login` (no admin credentials — ACR admin user is disabled on purpose).
- **ACME provider auth**: the `azuredns` DNS-01 challenge provider (`vancluever/acme`) defaults to the same `az login` shared credentials already used by `azurerm` — no separate service principal, no extra `ARM_*`/`AZURE_*` env vars needed, as long as whoever applies has rights on the DNS zone.

## Backend

Same Azure Blob Storage backend as `azure-virtual-network` (via `azure-tfstate-bootstrap`), different key: `container-apps-poc/terraform.tfstate`.

## `subscription_id`

Same gotcha as `azure-virtual-network`: set via `TF_VAR_subscription_id`, not `ARM_SUBSCRIPTION_ID` — the provider block reads the variable explicitly.

## Provider version

Pinned to azurerm `~> 5.4`, newer than `azure-virtual-network`'s `~> 4.0`. Deliberate — separate Terraform state, no compatibility constraint between the two, no reason to hold this one back. Note the schema difference this caused: `azurerm_private_dns_zone_virtual_network_link` and `azurerm_private_dns_a_record` take `private_dns_zone_id` in 5.x, not the `private_dns_zone_name` + `resource_group_name` / `zone_name` + `resource_group_name` style still used in `azure-virtual-network` on 4.x.

## Let's Encrypt rate limits

`acme_server_url` defaults to production (5 duplicate certs/domain/week limit). Switch to the [staging directory](https://letsencrypt.org/docs/staging-environment/) while iterating on config to avoid burning the limit on trial-and-error applies.

## Key Vault soft-delete

Same as `azure-virtual-network`'s vault: mandatory soft-delete (7 days), purge protection off. After a destroy, a re-apply with the same `key_vault_name` will hit a name conflict until the soft-deleted vault is purged or recovered — `az keyvault list-deleted`.

## Consumers

None yet — this is a leaf project, nothing else in the workspace reads its outputs.

## Relationship to `azure-virtual-network`

Reads (copied values, no `terraform_remote_state`): `containerapps_subnet_id`, `appgw_subnet_id`, `vnet_id`, `log_analytics_workspace_id`. Deliberately does NOT read `key_vault_id` (see Design decisions above). If a subnet CIDR, name, or output changes over there, check here before assuming it's safe.
