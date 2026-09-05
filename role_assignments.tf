resource "azurerm_role_assignment" "containerapp_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.containerapp_acr_pull.principal_id
}
