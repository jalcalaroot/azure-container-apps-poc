# Backend remoto en el mismo Azure Blob Storage que usa azure-virtual-network
# (provisionado por azure-tfstate-bootstrap). Key distinto para no pisar el
# state de la red.
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstatejohanaks"
    container_name       = "tfstate"
    key                  = "container-apps-poc/terraform.tfstate"
  }
}
