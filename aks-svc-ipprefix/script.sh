# Basic parameter
ranNum=$(echo $RANDOM)
rG=aks-ipprefix-${ranNum}
aks=aks-${ranNum}
aksVMSize=Standard_A4_v2
ipPrefix=ipprefix-${ranNum}
ipPrefixLength=30
location=southeastasia

echo "Your resource group will be: ${rG}"
az group create -n ${rG} -l ${location} -o none

# Create public IP prefix resource
az network public-ip prefix create -n ${ipPrefix} -g ${rG} \
--length ${ipPrefixLength} -o none

ipPrefixId=$(az resource list -g ${rG} \
    --resource-type Microsoft.Network/publicIPPrefixes \
    --query [0].id -o tsv)

# Create AKS
az aks create -n ${aks} -g ${rG} \
    --no-ssh-key -o none \
    --node-count 1 \
    --node-vm-size ${aksVMSize}

az aks get-credentials -n ${aks} -g ${rG}

# Grant permission with the scope of public IP prefix resource
aksIdentityType=$(az aks show -n ${aks} -g ${rG} \
--query identity.type -o tsv)

if [[ "$aksIdentityType" == "SystemAssigned" ]]
then
aksIdentityID=$(az aks show -n ${aks} -g ${rG} \
--query identity.principalId -o tsv)
fi

if [[ "$aksIdentityType" == "UserAssigned" ]]
then
aksIdentityID=$(az aks show -n ${aks} -g ${rG} \
--query identity.userAssignedIdentities.*.principalId -o tsv)
fi

if [[ "$aksIdentityType" == "" ]]
then
aksSPclientID=$(az aks show -n ${aks} -g ${rG} \
--query servicePrincipalProfile.clientId -o tsv)
aksIdentityID=$(az ad sp show --id ${aksSPclientID} --query id -o tsv)
fi

az role assignment create --assignee-object-id ${aksIdentityID} \
--assignee-principal-type ServicePrincipal --role "Network Contributor" \
--scope ${ipPrefixId} -o none

# Wait for the role assignment to take effect
sleep 10; 

# Deploy 4 services with same public IP prefix  
for i in {1..4}
do
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: test-svc-${i}
  labels:
    svc: test
  annotations:
    service.beta.kubernetes.io/azure-pip-prefix-id: |-
      ${ipPrefixId}
spec:
  selector:
    app.kubernetes.io/name: FakeApp
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
  type: LoadBalancer
EOF
sleep 5;
done

# Check result
sleep 15; kubectl get svc -l svc=test \
-o custom-columns=NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress..ip

# Clean resources
echo 'Demo completed. Press "y" to clean resources after you tested it out.'
az group delete -n ${rG} --no-wait
