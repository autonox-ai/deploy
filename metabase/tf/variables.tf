variable "metabase_host" {
  description = "Base URL of the Metabase instance (e.g. http://localhost:3000). The /api suffix is added automatically."
  type        = string
}

variable "metabase_username" {
  description = "Metabase admin email used to authenticate the provider."
  type        = string
}

variable "metabase_password" {
  description = "Metabase admin password."
  type        = string
  sensitive   = true
}

variable "pg_display_name" {
  description = "Human-readable name shown in Metabase for the AutoNox PostgreSQL data source."
  type        = string
  default     = "Autonox Postgres"
}

variable "pg_host" {
  description = "Hostname Metabase should use to reach the AutoNox PostgreSQL instance. From a Metabase docker container on the same compose network this is typically 'postgres' or 'nox-pg18'. From a Metabase container talking to a host-network Postgres, use 'host.docker.internal'."
  type        = string
}

variable "pg_port" {
  description = "PostgreSQL TCP port."
  type        = number
  default     = 5432
}

variable "pg_database" {
  description = "PostgreSQL database name. Defaults to the AutoNox bootstrap database."
  type        = string
  default     = "autonox"
}

variable "pg_user" {
  description = "PostgreSQL login role. The bireader role created by the AutoNox bootstrap is appropriate for read-only BI use."
  type        = string
  default     = "bireader"
}

variable "pg_password" {
  description = "Password for var.pg_user."
  type        = string
  sensitive   = true
}

variable "pg_ssl" {
  description = "Enable SSL when Metabase connects to PostgreSQL."
  type        = bool
  default     = false
}
