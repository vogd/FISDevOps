variable "cluster_name" {
  type    = string
  default = "chaos-cluster"
}

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "secondary_agent_region" {
  type        = string
  default     = "us-west-2"
  description = "Region for the failover DevOps Agent space"
}

variable "app_namespace" {
  type    = string
  default = "app"
}

variable "chaos_mesh_namespace" {
  type    = string
  default = "chaos-mesh"
}

variable "primary_agent_region" {
  type        = string
  default     = "us-east-1"
  description = "Region for the primary DevOps Agent space"
}
