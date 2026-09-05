# Importa el PFX generado por acme_certificate.this (certificate_p12, ya
# viene base64 + con la cadena completa) al Key Vault. Application Gateway
# lee este certificado via su propia identidad (ver app_gateway.tf).
resource "azurerm_key_vault_certificate" "this" {
  name         = "cert-${var.dns_record_name}"
  key_vault_id = azurerm_key_vault.this.id

  certificate {
    contents = acme_certificate.this.certificate_p12
    password = random_password.pfx.result
  }

  depends_on = [time_sleep.wait_for_kv_rbac]
}
