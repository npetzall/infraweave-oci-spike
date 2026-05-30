terraform {
  required_version = ">= 1.6.0"
}

module "module" {
  source = "oci://ghcr.io/<owner>/infraweave-oci-spike?tag=runnable"

  input = "called-from-project"
}
