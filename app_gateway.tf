resource "azurerm_public_ip" "appgw" {
  name                = "pip-${var.app_gateway_name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard" # requerido por Application Gateway v2
  tags                = local.tags
}

# Standard_v2 (sin WAF) para mantener costos bajos en una POC. Subir a
# WAF_v2 es un cambio de una linea si hace falta mas adelante.
resource "azurerm_application_gateway" "this" {
  name                = var.app_gateway_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = var.app_gateway_sku_capacity
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.appgw_kv_reader.id]
  }

  gateway_ip_configuration {
    name      = "gateway-ip-config"
    subnet_id = var.network_appgw_subnet_id
  }

  frontend_ip_configuration {
    name                 = "frontend-public"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = "port-80"
    port = 80
  }

  frontend_port {
    name = "port-443"
    port = 443
  }

  ssl_certificate {
    name                = "ssl-hello-world"
    key_vault_secret_id = azurerm_key_vault_certificate.this.secret_id
  }

  http_listener {
    name                           = "listener-http"
    frontend_ip_configuration_name = "frontend-public"
    frontend_port_name             = "port-80"
    protocol                       = "Http"
  }

  http_listener {
    name                           = "listener-https"
    frontend_ip_configuration_name = "frontend-public"
    frontend_port_name             = "port-443"
    protocol                       = "Https"
    ssl_certificate_name           = "ssl-hello-world"
    host_name                      = local.fqdn
  }

  backend_address_pool {
    name  = "beap-hello-world"
    fqdns = [azurerm_container_app.hello_world.ingress[0].fqdn]
  }

  probe {
    name                                      = "probe-hello-world"
    protocol                                  = "Http"
    path                                      = "/"
    interval                                  = 30
    timeout                                   = 30
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = true
  }

  backend_http_settings {
    name                                = "bes-hello-world"
    cookie_based_affinity               = "Disabled"
    port                                = 80
    protocol                            = "Http"
    pick_host_name_from_backend_address = true
    probe_name                          = "probe-hello-world"
    request_timeout                     = 30
  }

  redirect_configuration {
    name                 = "redirect-to-https"
    redirect_type        = "Permanent"
    target_listener_name = "listener-https"
    include_path         = true
    include_query_string = true
  }

  request_routing_rule {
    name                       = "rule-https"
    rule_type                  = "Basic"
    priority                   = 100
    http_listener_name         = "listener-https"
    backend_address_pool_name  = "beap-hello-world"
    backend_http_settings_name = "bes-hello-world"
  }

  request_routing_rule {
    name                        = "rule-http-redirect"
    rule_type                   = "Basic"
    priority                    = 110
    http_listener_name          = "listener-http"
    redirect_configuration_name = "redirect-to-https"
  }

  depends_on = [
    time_sleep.wait_for_kv_rbac,
    azurerm_key_vault_certificate.this,
  ]
}
