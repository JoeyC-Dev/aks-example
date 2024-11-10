#!/bin/bash
# Demo: Migrating to private cluster from public when using service prinipal
# https://blog.joeyc.dev/posts/aks-convert-public-to-private/

az extension add -n aks-preview

# Demo set-up
## Basic parameter
ranNum=$(echo $RANDOM)
rG=aks-${ranNum}
sp=aks-sp-${ranNum}
aks=aks-${ranNum}
vnet=aks-vnet
nodeCount=4
acr=aksacr${ranNum}
sa=akssa${ranNum}
ipPrefix=aksipp-${ranNum}
ipPrefixLength=31
location=southeastasia

## Name new user-assigned managed identity
uami=${aks}-newIdentity

echo "Your resource group will be: ${rG}"
az group create -n ${rG} -l ${location} -o none

## Preparing VNet
az network vnet create -g ${rG} -n ${vnet} \
--address-prefixes 10.208.0.0/12 -o none 
az network vnet subnet create -n akssubnet -o none \
--vnet-name ${vnet} -g ${rG} --address-prefixes 10.208.0.0/23

vnetId=$(az resource list -n ${vnet} -g ${rG} \
--resource-type Microsoft.Network/virtualNetworks \
--query [0].id -o tsv)

## Create AKS
### Preparing SP
spinfo=$(az ad sp create-for-rbac --name ${sp} -o json)
spAppId=$(echo $spinfo | jq -r .appId)
spSecret=$(echo $spinfo | jq -r .password)
aksIdentityId=$(az ad sp show \
--id ${spAppId} --query id -o tsv)
appObjectId=$(az ad app show \
--id ${spAppId} --query id -o tsv)

unset spinfo

### Grant permission to subnet for SP
az role assignment create --role "Network Contributor" \
--assignee-object-id ${aksIdentityId} -o none \
--scope ${vnetId}/subnets/akssubnet --assignee-principal-type ServicePrincipal

az aks create -n ${aks} -g ${rG} \
--no-ssh-key -o none \
--nodepool-name agentpool \
--node-os-upgrade-channel None \
--node-count ${nodeCount} \
--node-vm-size Standard_A4_v2 \
--network-plugin azure \
--service-principal ${spAppId} \
--client-secret ${spSecret} \
--vnet-subnet-id ${vnetId}/subnets/akssubnet

unset spAppId spSecret

az aks get-credentials -n ${aks} -g ${rG}

## Create external stroage account 
az storage account create \
-n ${sa} -g ${rG} -o none \
--kind StorageV2 \
--sku Standard_LRS 

### Wait for storage account to complete its provision
### then to get storage account resource ID
sleep 5;
saId=$(az resource list -n ${sa} -g ${rG} \
--resource-type Microsoft.Storage/storageAccounts \
--query [0].id -o tsv)

## Create Azure Container Registry
az acr create -n ${acr} -g ${rG} \
--sku Basic -o none
acrId=$(az resource list -n ${acr} -g ${rG} \
--resource-type Microsoft.ContainerRegistry/registries \
--query [0].id -o tsv)

## Create IP prefix
az network public-ip prefix create -n ${ipPrefix} -g ${rG} \
--length ${ipPrefixLength} -o none
ipPrefixId=$(az resource list -n ${ipPrefix} -g ${rG} \
--resource-type Microsoft.Network/publicIPPrefixes \
--query [0].id -o tsv)

## Grant resource permissions to current AKS security principal
az role assignment create --role "Network Contributor" \
--assignee-object-id ${aksIdentityId} -o none \
--scope ${ipPrefixId} --assignee-principal-type ServicePrincipal
az role assignment create --role "Storage Account Contributor" \
--assignee-object-id ${aksIdentityId} -o none \
--scope ${saId} --assignee-principal-type ServicePrincipal
az role assignment create --role "AcrPull" \
--assignee-object-id ${aksIdentityId} -o none \
--scope ${acrId} --assignee-principal-type ServicePrincipal

## Set up Kubernetes resources associated with external resources
az acr import -n ${acr} -o none -t nginx:alpine \
--source docker.io/library/nginx:alpine

for i in {1..2}
do
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: demo-svc-${i}
  labels:
    svc: test
  annotations:
    service.beta.kubernetes.io/azure-pip-prefix-id: |-
      ${ipPrefixId}
spec:
  selector:
    app.kubernetes.io/name: nginx
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
  type: LoadBalancer
EOF
sleep 5;
done

cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: demo-azurefile-csi-${ranNum}
provisioner: file.csi.azure.com
allowVolumeExpansion: true
parameters:
  storageAccount: ${sa}
  resourceGroup: ${rG}
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions:
  - dir_mode=0777
  - file_mode=0777
  - mfsymlinks
  - cache=strict
  - nosharesock
  - actimeo=30
  - nobrl
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-azurefile-pvc-${ranNum}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: demo-azurefile-csi-${ranNum}
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  labels:
    app: nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: nginx
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nginx
    spec:
      containers:
      - name: nginx
        image: ${acr}.azurecr.io/nginx:alpine
        ports:
          - containerPort: 80
        volumeMounts:
          - mountPath: /var/log/nginx
            name: azurefile
            subPath: log
      volumes:
        - name: azurefile
          persistentVolumeClaim: 
            claimName: demo-azurefile-pvc-${ranNum}
EOF

# Migrating to new managed identity
## Record old Security Principal ID
oldaksIdentityId=${aksIdentityId}

## Create a new user-assigned managed identity
az identity create -n ${uami} -g ${rG} -o none
uamiId=$(az resource list -n ${uami} -g ${rG} \
--resource-type Microsoft.ManagedIdentity/userAssignedIdentities \
--query [0].id -o tsv)
uamiIdentityId=$(az identity show --ids $uamiId \
--query principalId -o tsv)

## Get role assignment for current security principal
aksNrgId=$(az group show --query id -o tsv \
-n $(az aks show -n ${aks} -g ${rG} \
--query nodeResourceGroup -o tsv))

### Note: exclude ACR-related role assignments, as ACR DOES NOT rely on 
### the new AKS security principal to let AKS access it
assignmentList=$(az role assignment list --all --query \
"[?principalId=='${aksIdentityId}'&&"'!'"starts_with(scope,'${aksNrgId}') \
&&"'!'"contains(scope,'Microsoft.ContainerRegistry/registries')]. \
{roleId:roleDefinitionId,name:roleDefinitionName,scope:scope}")

## Assign permissions for external resources to new managed identity
assignmentNum=$(echo ${assignmentList} | jq length)
for ((i=0; i<${assignmentNum}; i++)); do 
  roleId=$(echo "${assignmentList}" | jq -r '.['$i'] | .roleId')
  scope=$(echo "${assignmentList}" | jq -r '.['$i'] | .scope')

  az role assignment create --role ${roleId} \
  --assignee-object-id ${uamiIdentityId} -o none\
  --scope ${scope} --assignee-principal-type ServicePrincipal
done

## Make AKS using new user-assigned managed identity
az aks update -n ${aks} -g ${rG} -o none \
--enable-managed-identity --assign-identity ${uamiId} --yes

## Re-attach acr to AKS
az aks update -n ${aks} -g ${rG} \
--attach-acr ${acrId} -o none

# Convert AKS to private cluster
## Create subnet for API servers
az network vnet subnet create -n apisubnet -o none \
--vnet-name ${vnet} -g ${rG} --address-prefixes 10.209.0.0/28

## Grant permissions for new subnet to new AKS security principal
az role assignment create --role "Network Contributor" \
--assignee-object-id ${uamiIdentityId} -o none \
--scope ${vnetId}/subnets/apisubnet --assignee-principal-type ServicePrincipal

## Configure node surge and drain timeout durations to speed up the process
az aks nodepool update -n agentpool -o none \
--cluster-name ${aks} -g ${rG} --max-surge 2 \
--drain-timeout 5

### Wait for role assignment to complete
sleep 5;

## Convert AKS to private cluster via API VNet Integration
az aks update -n ${aks} -g ${rG} --enable-apiserver-vnet-integration \
--apiserver-subnet-id ${vnetId}/subnets/apisubnet -o none
az aks update -n ${aks} -g ${rG} --enable-private-cluster -o none

# Clean old role assignments && service principal
oldassignmentItems=$(az role assignment list --all \
--query "[?principalId=='${oldaksIdentityId}'].id" -o tsv)
az role assignment delete --ids ${oldassignmentItems}

az ad app delete --id ${appObjectId} -o none

# Clean resources
echo 'Demo completed. Press "y" to clean resources after you tested it out.'
az group delete -n ${rG} --no-wait