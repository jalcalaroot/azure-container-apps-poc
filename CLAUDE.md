# azure-container-apps-poc

POC: hello-world container on Azure Container Apps (Consumption plan — the ECS-Fargate equivalent, not ACI, not AKS), behind Application Gateway with a Let's Encrypt cert, image in a dedicated ACR, monitored via the Log Analytics Workspace already created by `azure-virtual-network`.

## Design decisions worth knowing before changing anything

- **Container Apps Environment is internal-only** (`internal_load_balancer_enabled = true`). An *external* workload-profile environment routes inbound traffic through a Microsoft-managed public IP that bypasses the subnet's NSG entirely — internal-only is what makes Application Gateway the actual sole entry point, and what makes `nsg-containerapps` (in `azure-virtual-network`) meaningful at all. Don't flip this to external without also reconsidering whether the NSG design still holds.
- **This project has its own Key Vault** (`kv-jalcalaroot-capoc` - the obvious `kv-containerapps-poc` name was already taken globally by someone else, confirmed via `checkNameAvailability`, not a soft-delete of ours), separate from the network project's. That Key Vault is Private-Endpoint-only (`public_network_access_enabled = false`); importing an ACME certificate into a Key Vault is a *data-plane* operation, and a `terraform apply` run from outside the VNet (e.g. a laptop) can't reach a Private-Endpoint-only vault's data plane. Rather than requiring every apply to go through a jumpbox, this vault is RBAC-authorized and public (locked down by role assignment, not by network ACL).
- **No `prevent_destroy` anywhere.** Unlike `azure-virtual-network`, this is disposable POC infra by design — `terraform destroy` should just work.
- **Uses the existing `azure.jalcalaroot.com` zone (RG `jalcalaroot`), doesn't create a new one.** Referenced via `data "azurerm_dns_zone"` in `dns.tf`. It's already delegated/authoritative (other records live there, e.g. `ping`), so there's no NS-delegation step before the DNS-01 challenge works. Don't switch this back to creating a fresh zone without re-adding that delegation step.
- **RBAC propagation lag.** `time_sleep.wait_for_kv_rbac` (90s) exists because Azure role assignments can take a couple of minutes to actually take effect — without it, the first apply touching the Key Vault's data plane (cert import, or Application Gateway reading the cert) can 403 even though the role assignment already shows up in state. If you see a transient 403 on a fresh apply, this is why — don't "fix" it by removing the sleep, `terraform apply` again instead.
- **The image must already exist in ACR before the Container App is created/updated.** There's no Terraform resource that builds/pushes images. Build and `docker push` the `docker/` image to ACR before applying `container_apps.tf`, using `az acr login` (no admin credentials — ACR admin user is disabled on purpose).
- **ACME provider auth**: the `azuredns` DNS-01 challenge provider (`vancluever/acme`) defaults to the same `az login` shared credentials already used by `azurerm` — no separate service principal, no extra `ARM_*`/`AZURE_*` env vars needed, as long as whoever applies has rights on the DNS zone.
- **`acme_certificate` needs `common_name`, not `certificate_request_pem`.** The `certificate_p12` attribute (what `certificate.tf` imports into Key Vault) comes back **empty** when the cert is requested via an external CSR (`certificate_request_pem` + `tls_cert_request`) - it's only populated when `acme_certificate` generates its own key from `common_name`/`key_type`. Cost us one failed apply to find out (the error only surfaces at `azurerm_key_vault_certificate.this`: `"certificate.0.contents" to not be an empty string`). Don't reintroduce the CSR pattern here.
- **Container App needs `allow_insecure_connections = true` on its `ingress` block.** Application Gateway's `backend_http_settings` talks to the Container App over plain HTTP (port 80) inside the VNet - TLS already terminated at App Gateway. Without this flag, Container Apps' edge proxy enforces HTTPS and 301-redirects every request back to its own FQDN, which App Gateway just passes through to the client instead of following. Symptom: the site loads over HTTPS with a valid cert but returns a 301 to `https://<container-app-fqdn>` instead of the page.
- **`Microsoft.App` resource provider must be registered on the subscription** before the first `Container Apps Environment` apply, or it fails with `MissingSubscriptionRegistration` (409). One-time fix: `az provider register --namespace Microsoft.App` (takes a minute or two - poll with `az provider show -n Microsoft.App --query registrationState`).

## Backend

Same Azure Blob Storage backend as `jalcalaroot-azure-bootstrap` (`sttfstatejalcalaroot` in resource group `jalcalaroot`, `use_azuread_auth = true` - no storage account keys), different key: `container-apps-poc/terraform.tfstate`. NOT the `rg-tfstate`/`sttfstatejohanaks` backend referenced in some of this POC's earlier design notes - that backend belongs to the unrelated `xstratus/azure-virtual-network` repo and was never actually applied against this subscription.

## `subscription_id`

Same gotcha as `azure-virtual-network`: set via `TF_VAR_subscription_id`, not `ARM_SUBSCRIPTION_ID` — the provider block reads the variable explicitly.

## Provider version

Pinned to azurerm `~> 5.4`, newer than `azure-virtual-network`'s `~> 4.0`. Deliberate — separate Terraform state, no compatibility constraint between the two, no reason to hold this one back. Note the schema difference this caused: `azurerm_private_dns_zone_virtual_network_link` and `azurerm_private_dns_a_record` take `private_dns_zone_id` in 5.x, not the `private_dns_zone_name` + `resource_group_name` / `zone_name` + `resource_group_name` style still used in `azure-virtual-network` on 4.x.

## Let's Encrypt rate limits

`acme_server_url` defaults to production (5 duplicate certs/domain/week limit). Switch to the [staging directory](https://letsencrypt.org/docs/staging-environment/) while iterating on config to avoid burning the limit on trial-and-error applies.

## Key Vault soft-delete

Same as `azure-virtual-network`'s vault: mandatory soft-delete (7 days), purge protection off. After a destroy, a re-apply with the same `key_vault_name` will hit a name conflict until the soft-deleted vault is purged or recovered — `az keyvault list-deleted`.

## CI/CD

Two dedicated OIDC identities (`ci_identities.tf`): `containerapps-poc-agent` (apply, triggered by push to `main` AND the weekly schedule - both present the *same* GitHub OIDC subject claim, `ref:refs/heads/main`, so one federated credential covers both) and `containerapps-poc-plan` (read-only, PRs). Unlike `jalcalaroot-azure-bootstrap`'s identities (which get Contributor over the *entire* shared `jalcalaroot` resource group), these are scoped resource-by-resource: Contributor/Reader on `rg-containerapps-poc` itself, `DNS Zone Contributor`/`Reader` scoped to just the `azure.jalcalaroot.com` zone resource (not the `jalcalaroot` RG), `Network Contributor` scoped to just the `snet-containerapps` subnet (needed for the Container Apps Environment's subnet join, agent only), and `Storage Blob Data Contributor` on the tfstate storage account for both (plan needs write too - blob lease locking, same as `jalcalaroot-azure-bootstrap`'s gotcha). Least-privilege on purpose: a compromised workflow here can't touch the shared network.

- **GitHub's OIDC subject claim includes `@<owner_id>/@<repo_id>` by default now**, not just `repo:<owner>/<repo>:...`. Verify with `gh api repos/jalcalaroot/azure-container-apps-poc/actions/oidc/customization/sub` before assuming the "classic" format - guessing wrong here fails silently at runtime with `AADSTS70021`, not at plan time.
- **The `acme` provider needs its own `azure/login` step - `ARM_USE_OIDC` alone isn't enough.** `azurerm` resolves OIDC internally (reads `ARM_CLIENT_ID`/`ARM_TENANT_ID`/`ARM_SUBSCRIPTION_ID` + `ARM_USE_OIDC=true` and exchanges the GitHub token itself). The `acme` provider's `azuredns` DNS-01 challenge is a *separate* Go binary using `lego`'s own "Default Azure Credentials" resolution, which looks for `AZURE_FEDERATED_TOKEN_FILE`/`AZURE_CLIENT_ID`/`AZURE_TENANT_ID` - only the official `azure/login` action sets those up. Without it, `terraform apply`/`plan` succeed for every azurerm resource and then fail specifically on `acme_certificate`.
- **`azurerm_role_assignment.current_user_kv_admin` is `for_each`, not a single resource** - see the comment in `keyvault.tf`. This exists *because* of CI: without it, switching between a local apply (your user) and a CI apply (the agent identity) would destroy+recreate the KV admin assignment every time, briefly locking out whichever identity just stopped being "current". `extra_key_vault_admin_object_ids` is where you pin additional admins statically.
- **Checkov's inline skip comment must go *inside* the resource block, not on the line above it.** `#checkov:skip=CKV_XXX:reason` placed before `resource "..." "..." {` is silently ignored - Checkov still reports the check as `FAILED`. It only takes effect placed between the `{` and `}`. Cost us a debugging round-trip to confirm (tested with a minimal reproduction) since nothing errors, it just doesn't suppress.
- **`tflint`'s `azurerm_resources_missing_prevent_destroy` rule is disabled in `.tflint.hcl`.** It conflicts with this project's "no `prevent_destroy` anywhere, disposable POC" design decision (see above) - don't re-enable it without also reconsidering that decision.
- **16 Checkov findings are suppressed with `#checkov:skip`** across `acr.tf` (8, all Premium-SKU-only ACR features), `keyvault.tf` (5, consequences of the public+RBAC Key Vault decision above), and `app_gateway.tf` (3, the HTTP listener/backend and missing WAF, both already explained above). All are `soft_fail: false` in CI - genuinely blocking, not just warnings - so a real new finding will actually fail the PR, which is the point.

## Consumers

None yet — this is a leaf project, nothing else in the workspace reads its outputs.

## Relationship to `jalcalaroot-azure-bootstrap`

The real network (`vnet-jalcalaroot`) is provisioned by `jalcalaroot-azure-bootstrap/terraform/environments/dev`, which itself consumes a separately-versioned `git::github.com/jalcalaroot/azure-virtual-network.git` module (NOT the `xstratus/azure-virtual-network` repo this POC's design docs reference elsewhere - same design, different repo, naming collision worth remembering). The `snet-containerapps` subnet this POC needs was added directly in that `environments/dev` root module (not in the versioned module) via the `feat/containerapps-subnet` branch/PR, to avoid bumping the module version.

Reads (copied values, no `terraform_remote_state`): `containerapps_subnet_id`, `appgw_subnet_id`, `vnet_id`, `log_analytics_workspace_id`. Deliberately does NOT read `key_vault_id` (`kv-jalcalaroot-net` - see Design decisions above). If a subnet CIDR, name, or output changes over there, check here before assuming it's safe.
