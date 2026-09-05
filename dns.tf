# Azure DNS Zone para el dominio de este proyecto. Crear la zone aqui NO la
# hace autoritativa por si sola - hay que delegar los NS records desde donde
# sea que se gestione el dominio padre (jalcalaroot.com) hacia los name
# servers que Azure asigna a esta zone (ver output dns_zone_name_servers).
# Sin esa delegacion, ni la resolucion publica ni el DNS-01 challenge de
# Let's Encrypt van a funcionar.
resource "azurerm_dns_zone" "this" {
  name                = var.dns_zone_name
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_dns_a_record" "container" {
  name                = var.dns_record_name
  zone_name           = azurerm_dns_zone.this.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 300
  records             = [azurerm_public_ip.appgw.ip_address]
}
