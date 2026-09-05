# Azure Monitor - reutilizamos el Log Analytics Workspace de
# azure-virtual-network (var.network_log_analytics_workspace_id) en vez de
# crear uno nuevo, igual que ya hace ese proyecto para si mismo.

resource "azurerm_monitor_diagnostic_setting" "container_app_environment" {
  name                       = "diag-container-app-environment"
  target_resource_id         = azurerm_container_app_environment.this.id
  log_analytics_workspace_id = var.network_log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "app_gateway" {
  name                       = "diag-app-gateway"
  target_resource_id         = azurerm_application_gateway.this.id
  log_analytics_workspace_id = var.network_log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "acr" {
  name                       = "diag-acr"
  target_resource_id         = azurerm_container_registry.this.id
  log_analytics_workspace_id = var.network_log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
