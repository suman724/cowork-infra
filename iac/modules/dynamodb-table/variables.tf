variable "table_name" {
  description = "Name of the DynamoDB table"
  type        = string
}

variable "hash_key" {
  description = "Partition key attribute name"
  type        = string
}

variable "range_key" {
  description = "Sort key attribute name (optional)"
  type        = string
  default     = null
}

variable "attributes" {
  description = "List of attribute definitions (name + type). Must include hash_key and any GSI keys."
  type = list(object({
    name = string
    type = string # S = String, N = Number, B = Binary
  }))
}

variable "global_secondary_indexes" {
  description = "List of GSI definitions"
  type = list(object({
    name            = string
    hash_key        = string
    range_key       = optional(string)
    projection_type = optional(string, "ALL")
  }))
  default = []
}

variable "ttl_attribute" {
  description = "Name of the TTL attribute"
  type        = string
  default     = "ttl"
}

variable "ttl_enabled" {
  description = "Whether TTL is enabled"
  type        = bool
  default     = true
}

variable "point_in_time_recovery" {
  description = "Enable point-in-time recovery"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags to apply"
  type        = map(string)
  default     = {}
}
