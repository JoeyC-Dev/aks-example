#!/bin/bash
# Demo: Create an unmanaged gateway controller in AKS with NGINX Gateway Fabric
# https://blog.joeyc.dev/posts/aks-impersonation-aad/

curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

install -m 0755 kubectl ~/.local/bin/kubectl && source ~/.bashrc

kubectl version

# Create AKS
ranChar=$(tr -dc 0-9 < /dev/urandom | head -c 6)
rG=aks-${ranChar}
aks=aks-${ranChar}
vnet=aks-vnet
location=southeastasia

echo "Your resource group will be: ${rG}"
az group create -n ${rG} -l ${location} -o none

az network vnet create -g ${rG} -n ${vnet} --address-prefixes ['10.208.0.0/16','10.209.0.0/16'] -o none 
az network vnet subnet create -n akssubnet -g ${rG} --vnet-name ${vnet} --address-prefixes 10.208.0.0/25 -o none --no-wait

vnetId=$(az resource list -n ${vnet} -g ${rG} \
    --resource-type Microsoft.Network/virtualNetworks \
    --query [0].id -o tsv)

az aks create -n ${aks} -g ${rG} \
    --no-ssh-key -o none \
    --nodepool-name agentpool --enable-blob-driver \
    --node-os-upgrade-channel None \
    --node-count 1 \
    --node-vm-size Standard_B2s \
    --network-plugin azure \
    --vnet-subnet-id ${vnetId}/subnets/akssubnet


# Parameter set-up and account creation
aksId=$(az resource list -n ${aks} -g ${rG} \
    --resource-type Microsoft.ContainerService/managedClusters \
    --query [0].id -o tsv)

userObjectId=$(az ad signed-in-user show --query id -o tsv)

DOMAIN=lifterdartlumberduck.onmicrosoft.com
PASSWORD=Password1

az ad user create -o none \
    --display-name aksreadonlyuser \
    --password ${PASSWORD} \
    --user-principal-name aksreadonlyuser@${DOMAIN} 

externalUserId=$(az ad user show -o tsv --query id \
    --id aksreadonlyuser@${DOMAIN})


# ABAC AKS
az aks update -n ${aks} -g ${rG} -o none \
    --enable-aad --enable-azure-rbac

az aks get-credentials -n ${aks} -g ${rG}

az role assignment create --role "Azure Kubernetes Service RBAC Cluster Admin" \
    --assignee-object-id ${userObjectId} -o none \
    --scope ${aksId} --assignee-principal-type User


az role assignment create --role "Azure Kubernetes Service RBAC Reader" \
    --assignee-object-id ${externalUserId} -o none \
    --scope ${aksId} --assignee-principal-type User

kubelogin remove-cache-dir

kubectl auth can-i get pod --as ${userObjectId} --as-user-extra oid=${userObjectId}
kubectl auth can-i get secret --as ${userObjectId} --as-user-extra oid=${userObjectId}

kubectl auth can-i get pod --as ${externalUserId} --as-user-extra oid=${externalUserId}
kubectl auth can-i get secret --as ${externalUserId} --as-user-extra oid=${externalUserId}



# Convert to Non-ABAC AKS
az aks update -n ${aks} -g ${rG} -o none \
    --disable-azure-rbac

az aks get-credentials -n ${aks} -g ${rG} --admin

<<EOF kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: pod-access-role
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
EOF

<<EOF kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: pod-secret-access-role
rules:
- apiGroups: [""]
  resources: ["pods", "secrets"]
  verbs: ["get", "list"]
EOF

<<EOF kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: impersonate-role
rules:
- apiGroups: ["", "authentication.k8s.io"]
  resources: ["users", "groups", "userextras/oid"]
  verbs: ["impersonate"]
EOF

<<EOF kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: access-to-pod-secret
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: ${userObjectId}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: pod-secret-access-role
EOF

<<EOF kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: action-to-impersonate
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: ${userObjectId}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: impersonate-role
EOF

<<EOF kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: access-to-pod
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: ${externalUserId}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: pod-access-role
EOF

az aks get-credentials -n ${aks} -g ${rG}

kubectl auth can-i get pod --as ${userObjectId}
kubectl auth can-i get secret --as ${userObjectId}

kubectl auth can-i get pod --as ${externalUserId}
kubectl auth can-i get secret --as ${externalUserId}

# Clean resources
echo 'Demo completed. Press "y" to clean resources after you tested it out.'
az ad user delete --id ${externalUserId} -o none
az group delete -n ${rG} --no-wait

rm ~/.local/bin/kubectl && source ~/.bashrc
