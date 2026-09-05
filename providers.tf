# NOTA: este proyecto usa azurerm ~> 5.4 (mas reciente que el ~> 4.0 fijado
# en azure-virtual-network). Son states independientes - no hay ninguna
# restriccion real de compatibilidad entre ellos, asi que no hay razon para
# arrastrar la version mas vieja aqui.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.4"
    }
    acme = {
      source  = "vancluever/acme"
      version = "~> 3.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
    key_vault {
      purge_soft_deleted_certificates_on_destroy = true
      purge_soft_deleted_keys_on_destroy         = true
      purge_soft_deleted_secrets_on_destroy      = true
    }
  }
}

# El challenge DNS-01 de "azuredns" (ver acme.tf) usa por defecto las mismas
# credenciales que ya tengas activas via `az login` (Default Azure
# Credentials -> Shared credentials en ~/.azure) - no hace falta un service
# principal ni variables adicionales mientras el usuario que corre
# `terraform apply` tenga permisos sobre la DNS zone.
provider "acme" {
  server_url = var.acme_server_url
}
