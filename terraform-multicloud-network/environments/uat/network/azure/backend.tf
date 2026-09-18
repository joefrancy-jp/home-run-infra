# Remote state in an Azure Storage Account blob container.
#
# "key" is passed by deploy.sh at init time as:
#   <resource>/<env>-home-run-azure.tfstate   (e.g. network/dev-home-run-azure.tfstate)
# Locking is built in (blob lease).
terraform {
  backend "azurerm" {
    resource_group_name  = "CHANGE-ME-tfstate-rg"
    storage_account_name = "changemetfstate"
    container_name       = "tfstate"
  }
}
