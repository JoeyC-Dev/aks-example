This script is a demonstration to show how to build an AKS with keda-http-addon, and how it performs when under stress testing.  
  
Keda http add-on official walkthrough: https://github.com/kedacore/http-add-on/blob/main/docs/walkthrough.md  
  
This script will create:
- One AKS instance with approuting and keda
- One Azure Load Testing instance

> Note: This script will use `nip.io` as external ip-to-domain service in Ingress for Load Testing.  