variable "snowflake_organization_name" {
  description = "Snowflake organization name"
  type        = string
}

variable "snowflake_account_name" {
  description = "Snowflake account name"
  type        = string
}

variable "snowflake_user" {
  description = "Snowflake user for Terraform operations"
  type        = string
}

variable "snowflake_role" {
  description = "Snowflake role for Terraform operations (ACCOUNTADMIN required for resource monitors and compute pools)"
  type        = string
  default     = "ACCOUNTADMIN"
}

variable "snowflake_private_key" {
  description = "RSA private key content (PKCS8 PEM) for key-pair authentication"
  type        = string
  sensitive   = true
}
