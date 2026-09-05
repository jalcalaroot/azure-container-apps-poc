output "fqdn" {
  description = "Dominio publico final (una vez delegado el DNS)"
  value       = local.fqdn
}

output "app_gateway_public_ip" {
  description = "IP publica del Application Gateway - usarla si delegas el dominio manualmente en vez de vía este proyecto"
  value       = azurerm_public_ip.appgw.ip_address
}

output "dns_zone_name_servers" {
  description = "Name servers asignados por Azure DNS - delegar estos NS records desde el dominio padre (jalcalaroot.com) para que la zone sea autoritativa"
  value       = azurerm_dns_zone.this.name_servers
}

output "acr_login_server" {
  description = "Login server del ACR - usar para docker build/push (ver README)"
  value       = azurerm_container_registry.this.login_server
}

output "container_app_environment_default_domain" {
  description = "Dominio interno del Container Apps Environment (usado por la Private DNS Zone)"
  value       = azurerm_container_app_environment.this.default_domain
}

output "container_app_fqdn" {
  description = "FQDN interno del Container App (solo resoluble dentro de la VNet)"
  value       = azurerm_container_app.hello_world.ingress[0].fqdn
}

output "key_vault_name" {
  description = "Nombre del Key Vault dedicado a este proyecto"
  value       = azurerm_key_vault.this.name
}
