# Container Apps Environment - internal-only a proposito (ver
# containerapps_subnet.tf en azure-virtual-network para el porque). Application
# Gateway es el unico punto de entrada publico; llega a este environment por
# su IP interna dentro de la VNet.
resource "azurerm_container_app_environment" "this" {
  name                = var.container_app_environment_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  infrastructure_subnet_id       = var.network_containerapps_subnet_id
  internal_load_balancer_enabled = true

  logs_destination           = "log-analytics"
  log_analytics_workspace_id = var.network_log_analytics_workspace_id

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  tags = local.tags
}

# Un environment interno NO registra su dominio por defecto en ninguna zona
# que la VNet pueda resolver - hay que crear la Private DNS Zone a mano con
# el nombre exacto de "default_domain" y linkearla a la VNet, si no
# Application Gateway nunca va a poder resolver el FQDN del Container App.
resource "azurerm_private_dns_zone" "containerapps" {
  name                = azurerm_container_app_environment.this.default_domain
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "containerapps" {
  name                 = "link-containerapps"
  private_dns_zone_id  = azurerm_private_dns_zone.containerapps.id
  virtual_network_id   = var.network_vnet_id
  registration_enabled = false
  tags                 = local.tags
}

resource "azurerm_private_dns_a_record" "containerapps_wildcard" {
  name                = "*"
  private_dns_zone_id = azurerm_private_dns_zone.containerapps.id
  ttl                 = 300
  records             = [azurerm_container_app_environment.this.static_ip_address]
}

resource "azurerm_container_app" "hello_world" {
  name                         = var.container_app_name
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.containerapp_acr_pull.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.containerapp_acr_pull.id
  }

  template {
    container {
      name   = "hello-world"
      image  = "${azurerm_container_registry.this.login_server}/hello-world:${var.container_image_tag}"
      cpu    = var.container_cpu
      memory = var.container_memory
    }

    min_replicas = 1
    max_replicas = 2
  }

  ingress {
    external_enabled = true # "external" = alcanzable desde fuera del environment (App Gateway), no desde internet - el environment es internal-only
    target_port      = 80

    # Sin esto, el edge proxy de Container Apps fuerza HTTPS y devuelve 301
    # ante cualquier request HTTP plano - exactamente lo que le llega desde
    # Application Gateway (backend_http_settings usa protocol = "Http" en
    # app_gateway.tf). TLS ya termino en App Gateway con el cert de Let's
    # Encrypt; este tramo interno vive enteramente dentro de la VNet
    # (environment internal-only), asi que HTTP plano aca es la superficie
    # esperada, no una regresion de seguridad.
    allow_insecure_connections = true

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  depends_on = [azurerm_role_assignment.containerapp_acr_pull]

  tags = local.tags
}
