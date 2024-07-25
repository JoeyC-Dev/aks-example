#!/bin/bash
# https://blog.joeyc.dev/posts/aks-approuting-defaultcert/

ranNum=$(echo $RANDOM)
region=westus
rG=aks-approuting-${ranNum}
kv=kvaks${ranNum}
aks=aks-${ranNum}
aksVer=1.30

cert_name=example-meow-${ranNum}

# Initial set-up
echo "Your resource group will be: ${rG}"
az group create -n ${rG} -l ${region} -o none

az aks create -n ${aks} -g ${rG} --kubernetes-version ${aksVer} --node-os-upgrade-channel None \
--node-vm-size Standard_A4_v2 --node-count 1 --enable-app-routing --no-ssh-key -o none
infra_rG=$(az aks show -n ${aks} -g ${rG} --query nodeResourceGroup -o tsv)

## Get AKS credentials 
az aks get-credentials -n ${aks} -g ${rG}

# Deploy default cert via key vault
## Create Key Vault with set-policy mode
az keyvault create -n ${kv} -g ${rG} --enable-rbac-authorization false -o none
kvURI=$(az resource show -n ${kv} -g ${rG} --namespace Microsoft.KeyVault --resource-type vaults --query id -o tsv)

## Attach Key Vault to approuting
az aks approuting update -n ${aks} -g ${rG} --enable-kv --attach-kv ${kvURI} -o none

# ## Grant permission to KV (This process is not needed)
# kvprovider_mi_client_id=$(az identity show --resource-group ${infra_rG} --name "azurekeyvaultsecretsprovider-${aks}" --query clientId -o tsv)
# az keyvault set-policy -n ${kv} --certificate-permissions get --spn ${kvprovider_mi_client_id} -o none

# webapp_mi_client_id=$(az identity show --resource-group ${infra_rG} --name "webapprouting-${aks}" --query clientId -o tsv)
# az keyvault set-policy -n ${kv} --certificate-permissions get --spn ${webapp_mi_client_id} -o none

## Generate certificate
openssl req -new -x509 -nodes -subj "/CN=${cert_name}-kv" -addext "subjectAltName=DNS:${cert_name}-kv" -out ${cert_name}-kv.crt -keyout ${cert_name}-kv.key
echo "Setting password for certificate. You can skip it by pressing Enter..."
openssl pkcs12 -export -in ${cert_name}-kv.crt -inkey ${cert_name}-kv.key -out ${cert_name}-kv.pfx

## Import certificate into Key Vault
az keyvault certificate import --vault-name ${kv} -n ${cert_name} -f ${cert_name}-kv.pfx -o none
certUrl=$(az keyvault certificate show --vault-name ${kv} -n ${cert_name} --query id -o tsv | sed -E 's/((.*)([\/]))([a-z0-9]+)/\2/')

## Configure approuting
cat <<EOF | kubectl apply -f -
apiVersion: approuting.kubernetes.azure.com/v1alpha1
kind: NginxIngressController
metadata:
  name: default
spec:
  ingressClassName: webapprouting.kubernetes.azure.com
  controllerNamePrefix: nginx
  defaultSSLCertificate:
    keyVaultURI: ${certUrl}
EOF

## Waiting for certificate being refreshed
sleep 30;

## Check cert info
appKv_IP=$(kubectl get svc nginx -n app-routing-system -o json | jq -r '.status.loadBalancer.ingress | .[0].ip')
echo "Showing cert info while Key Vault URL is configured as default certificate..."
openssl s_client -showcerts -connect ${appKv_IP}:443 </dev/null | grep $"{cert_name}"


# Deploy default cert via Kubernetes secret
## Generate certificate
openssl req -new -x509 -nodes -subj "/CN=${cert_name}-local" -addext "subjectAltName=DNS:${cert_name}-local" -out ${cert_name}-local.crt -keyout ${cert_name}-local.key

## Import certificate into secret
kubectl create secret tls defaultcert --cert=${cert_name}-local.crt --key=${cert_name}-local.key

## Configure approuting
cat <<EOF | kubectl apply -f -
apiVersion: approuting.kubernetes.azure.com/v1alpha1
kind: NginxIngressController
metadata:
  name: default2
spec:
  ingressClassName: webapprouting2.kubernetes.azure.com
  controllerNamePrefix: nginx2
  defaultSSLCertificate:
    secret:
      name: defaultcert
      namespace: default
EOF

## Waiting for certificate being refreshed
sleep 30; 

## Check cert info
appSec_IP=$(kubectl get svc nginx2-0 -n app-routing-system -o json | jq -r '.status.loadBalancer.ingress | .[0].ip')
echo "Showing cert info while secret is configured as default certificate..."
openssl s_client -showcerts -connect ${appSec_IP}:443 </dev/null | grep $"{cert_name}"

# Clean resources
echo 'Demo completed. Press "y" to clean resources after you tested it out.'
az group delete -n ${rG} --no-wait
