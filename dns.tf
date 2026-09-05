# La zone "azure.jalcalaroot.com" ya existe y ya esta delegada (se usa para
# otros registros, ej. "ping"). No la creamos - la referenciamos y le
# agregamos el registro "container". Esto evita todo el paso manual de
# delegar NS records desde el dominio padre: al ser una zone ya autoritativa,
# el DNS-01 challenge de Let's Encrypt funciona desde el primer apply.
data "azurerm_dns_zone" "this" {
  name                = var.dns_zone_name
  resource_group_name = var.dns_zone_resource_group_name
}

resource "azurerm_dns_a_record" "container" {
  name                = var.dns_record_name
  zone_name           = data.azurerm_dns_zone.this.name
  resource_group_name = data.azurerm_dns_zone.this.resource_group_name
  ttl                 = 300
  records             = [azurerm_public_ip.appgw.ip_address]
}
