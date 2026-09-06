plugin "azurerm" {
  enabled = true
  version = "0.32.0" # verificar/actualizar contra la última release de tflint-ruleset-azurerm
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Deshabilitada a proposito: este proyecto es ephemeral/reproducible por
# diseño (ver CLAUDE.md "No prevent_destroy anywhere") - el Key Vault y su
# certificado deben poder destruirse limpio con `terraform destroy`, no
# quedar protegidos como en azure-virtual-network.
rule "azurerm_resources_missing_prevent_destroy" {
  enabled = false
}
