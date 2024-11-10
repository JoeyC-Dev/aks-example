This script is a demonstration to show how to convert an existing public AKS cluster to private cluster. The demonstration includes two different types of public clusters (scenarios), with different types of security principals:
- System-assigned managed idenity (Script: [from-system-assigned-managed-identity-aks.sh](./from-system-assigned-managed-identity-aks.sh))
- Service Principal (Script: [from-service-principal-aks.sh](./from-service-principal-aks.sh))

Link: https://blog.joeyc.dev/posts/aks-convert-public-to-private/

Each script will create:
- One AKS instance
- One ACR instance
- One public IP prefix resource
- One user-assigned managed identity
- (SP AKS only) One Service Principal