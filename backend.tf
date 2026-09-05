# Backend remoto real: el mismo storage account de tfstate que usa
# jalcalaroot-azure-bootstrap (sttfstatejalcalaroot, RG jalcalaroot), key
# distinto para no pisar el state de "dev". use_azuread_auth = true porque
# ese storage account tiene shared_access_key_enabled = false - el acceso es
# 100% via RBAC (Storage Blob Data Contributor/Reader), no account keys.
terraform {
  backend "azurerm" {
    resource_group_name  = "jalcalaroot"
    storage_account_name = "sttfstatejalcalaroot"
    container_name       = "tfstate"
    key                  = "container-apps-poc/terraform.tfstate"
    use_azuread_auth     = true
  }
}
