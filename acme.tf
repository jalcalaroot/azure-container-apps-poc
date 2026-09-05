# Certificado Let's Encrypt via DNS-01 contra la Azure DNS Zone existente
# referenciada en dns.tf. El challenge lo resuelve el provider "azuredns" del
# provider acme, que por defecto usa las mismas credenciales de `az login`
# que ya usa azurerm en este proyecto (Default Azure Credentials -> shared
# credentials en ~/.azure) - no requiere un service principal aparte. Al ser
# una zone ya delegada/autoritativa, no hace falta ningun paso manual previo.

resource "tls_private_key" "acme_account" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "acme_registration" "this" {
  account_key_pem = tls_private_key.acme_account.private_key_pem
  email_address   = var.acme_email
}

# NO usamos certificate_request_pem/tls_cert_request aca a proposito: el
# atributo certificate_p12 (que necesitamos para importar a Key Vault en
# certificate.tf) viene VACIO cuando el certificado se pide con un CSR
# externo - solo se genera cuando acme_certificate crea su propia key via
# common_name. Nos costo un intento fallido de apply descubrirlo.
resource "acme_certificate" "this" {
  account_key_pem = acme_registration.this.account_key_pem
  common_name     = local.fqdn
  key_type        = "RSA2048"

  # PFX password para el certificate_p12 (usado luego por
  # azurerm_key_vault_certificate en certificate.tf).
  certificate_p12_password = random_password.pfx.result

  dns_challenge {
    provider = "azuredns"

    config = {
      AZURE_ZONE_NAME       = data.azurerm_dns_zone.this.name
      AZURE_RESOURCE_GROUP  = data.azurerm_dns_zone.this.resource_group_name
      AZURE_SUBSCRIPTION_ID = var.subscription_id
    }
  }
}

resource "random_password" "pfx" {
  length  = 32
  special = false
}
