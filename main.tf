locals {
  base_tags = {
    ambiente    = var.environment
    propietario = var.owner
    proyecto    = var.project
  }

  tags = merge(local.base_tags, var.tags)

  fqdn = "${var.dns_record_name}.${var.dns_zone_name}"
}

data "azurerm_client_config" "current" {}

# Resource group dedicado - deliberadamente SIN lifecycle.prevent_destroy:
# a diferencia de azure-virtual-network, esta infra esta pensada para
# levantarse y tirarse sin friccion (ambiente reproducible bajo demanda,
# no un sistema con promesa de disponibilidad).
resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}
