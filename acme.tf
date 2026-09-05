# Certificado Let's Encrypt via DNS-01 contra la Azure DNS Zone de dns.tf.
# El challenge lo resuelve el provider "azuredns" del provider acme, que por
# defecto usa las mismas credenciales de `az login` que ya usa azurerm en
# este proyecto (Default Azure Credentials -> shared credentials en
# ~/.azure) - no requiere un service principal aparte. Ver README para el
# prerequisito de delegar los NS records ANTES de aplicar esto: si la zone
# no es autoritativa todavia, Let's Encrypt no puede ver el TXT del
# challenge y la emision falla.

resource "tls_private_key" "acme_account" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "acme_registration" "this" {
  account_key_pem = tls_private_key.acme_account.private_key_pem
  email_address   = var.acme_email
}

resource "tls_private_key" "cert" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "this" {
  private_key_pem = tls_private_key.cert.private_key_pem
  dns_names       = [local.fqdn]

  subject {
    common_name = local.fqdn
  }
}

resource "acme_certificate" "this" {
  account_key_pem         = acme_registration.this.account_key_pem
  certificate_request_pem = tls_cert_request.this.cert_request_pem

  # PFX password para el certificate_p12 (usado luego por
  # azurerm_key_vault_certificate en certificate.tf).
  certificate_p12_password = random_password.pfx.result

  dns_challenge {
    provider = "azuredns"

    config = {
      AZURE_ZONE_NAME       = azurerm_dns_zone.this.name
      AZURE_RESOURCE_GROUP  = azurerm_resource_group.this.name
      AZURE_SUBSCRIPTION_ID = var.subscription_id
    }
  }

  depends_on = [azurerm_dns_zone.this]
}

resource "random_password" "pfx" {
  length  = 32
  special = false
}
