variable "github_repo_url" {
  type        = string
  description = "Full URL to your GitHub Repository (e.g., https://github.com/nus-iss-dmss-practice-module-team5/team5-ewaste-platform)"
  default     = "https://github.com/nus-iss-dmss-practice-module-team5/team5-ewaste-platform"
}

variable "github_runner_token" {
  type        = string
  sensitive   = true
  description = "Registration token from GitHub (Settings -> Actions -> Runners -> New runner)"
}

variable "vm_admin_username" {
  type        = string
  default     = "azureuser"
  description = "Admin username for the Runner Linux VM."
}