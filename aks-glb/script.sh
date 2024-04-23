#!/bin/bash
# https://blog.joeyc.dev/posts/aks-glb/

randomNum=$(echo $RANDOM)
rG_region=westus
rG=my_aks_glb_${randomNum}

aks1=my-aks-${randomNum}-australiaeast
aks1_region=australiaeast
aks2=my-aks-${randomNum}-italynorth
aks2_region=italynorth

glb=my_glb_${randomNum}
glb_region=${rG_region}
glb_ip=my_glb_ip

# Create resource group
echo "Your resource group will be: ${rG}"
az group create -n ${rG} -l ${rG_region} -o none

# Create two AKS instances
az aks create -n ${aks1} -g ${rG} -l ${aks1_region} --node-vm-size Standard_A4_v2 --node-count 1 --no-ssh-key --no-wait --only-show-errors
az aks create -n ${aks2} -g ${rG} -l ${aks2_region} --node-vm-size Standard_A4_v2 --node-count 1 --no-ssh-key --no-wait --only-show-errors

infra1_rG=$(az aks show -n ${aks1} -g ${rG} --query nodeResourceGroup -o tsv --only-show-errors)
infra2_rG=$(az aks show -n ${aks2} -g ${rG} --query nodeResourceGroup -o tsv --only-show-errors)

# Create glb
az network public-ip create -n ${glb_ip} -g ${rG} -l ${glb_region} \
--version IPv4 --tier global --sku Standard -o none --only-show-errors
az network cross-region-lb create -n ${glb} -g ${rG} -l ${glb_region} \
--frontend-ip-name ${glb_ip} --public-ip-address ${glb_ip} \
--backend-pool-name kubernetes_lbs --no-wait

glb_ip_address=$(az network public-ip show -n ${glb_ip} -g ${rG} --query ipAddress -o tsv)

# Apply example applications with embedded glb IP
while [ "Succeeded" != "$(az aks show -n ${aks1} -g ${rG} --query provisioningState -o tsv --only-show-errors)" ]; \
do echo "Waiting until the cluster ${aks1} is being provisioned..."; sleep 10; done; \
az aks get-credentials -n ${aks1} -g ${rG} --only-show-errors; \
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: helloworld
spec:
  replicas: 1
  selector:
    matchLabels:
      app: helloworld
  template:
    metadata:
      labels:
        app: helloworld
    spec:
      containers:
      - name: helloworld
        image: us-docker.pkg.dev/google-samples/containers/gke/hello-app:1.0
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: helloworld
  annotations:
    service.beta.kubernetes.io/azure-additional-public-ips: ${glb_ip_address}
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: helloworld
EOF


while [ "Succeeded" != "$(az aks show -n ${aks2} -g ${rG} --query provisioningState -o tsv --only-show-errors)" ]; \
do echo "Waiting until the cluster ${aks2} is being provisioned..."; sleep 10; done; \
az aks get-credentials -n ${aks2} -g ${rG} --only-show-errors; \
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: helloworld
spec:
  replicas: 1
  selector:
    matchLabels:
      app: helloworld
  template:
    metadata:
      labels:
        app: helloworld
    spec:
      containers:
      - name: helloworld
        image: us-docker.pkg.dev/google-samples/containers/gke/hello-app:1.0
        ports:
        - containerPort: 8000
---
apiVersion: v1
kind: Service
metadata:
  name: helloworld
  annotations:
    service.beta.kubernetes.io/azure-additional-public-ips: ${glb_ip_address}
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: helloworld
EOF

# NSG: Disable Direct Access to AKS LB
function query1 { az resource list -g ${infra1_rG} --resource-type Microsoft.Network/publicIPAddresses --query '[].{id:id, "k8s-service":tags."k8s-azure-service"}' -o json | jq -r '.[] | select(."k8s-service"=="default/helloworld") | .id'; }
function query2 { az resource list -g ${infra2_rG} --resource-type Microsoft.Network/publicIPAddresses --query '[].{id:id, "k8s-service":tags."k8s-azure-service"}' -o json | jq -r '.[] | select(."k8s-service"=="default/helloworld") | .id'; }

# This is god misleading result
# az resource list -g ${infra1_rG} --resource-type Microsoft.Network/publicIPAddresses --query '[?tags."k8s-azure-service"=="default/helloworld"].id' -o tsv

while [ ! -n $(query1) ]; \
do echo "The IP is still pending creation; retry after 5s..."; sleep 5; \
done; \
ip1=$(query1); \
ip1Address=$(az network public-ip show --ids "${ip1}" --query ipAddress -o tsv)

while [ ! -n $(query2) ]; \
do echo "The IP is still pending creation; retry after 5s..."; sleep 5; \
done; \
ip2=$(query2); \
ip2Address=$(az network public-ip show --ids "${ip2}" --query ipAddress -o tsv)

nsg1=$(az resource list -g ${infra1_rG} --resource-type Microsoft.Network/networkSecurityGroups --query [0].name -o tsv)
nsg2=$(az resource list -g ${infra2_rG} --resource-type Microsoft.Network/networkSecurityGroups --query [0].name -o tsv)

az network nsg rule create --nsg-name ${nsg1} -g ${infra1_rG} --name "DenyLB_helloworld" \
--priority 234 --access Deny --protocol "*" --destination-address-prefixes ${ip1Address} \
--direction Inbound --no-wait 

az network nsg rule create --nsg-name ${nsg2} -g ${infra2_rG} --name "DenyLB_helloworld" \
--priority 234 --access Deny --protocol "*" --destination-address-prefixes ${ip2Address} \
--direction Inbound --no-wait 

# Link AKS LB IPs to GLB
lb1_frontendip=$(az network lb frontend-ip list --lb-name kubernetes -g ${infra1_rG} -o json --query "[].{id:id, publicIPAddressID:publicIPAddress.id}" | jq --arg var1 "$ip1" -r '.[] | select(.publicIPAddressID==$var1) | .id')
lb2_frontendip=$(az network lb frontend-ip list --lb-name kubernetes -g ${infra2_rG} -o json --query "[].{id:id, publicIPAddressID:publicIPAddress.id}" | jq --arg var2 "$ip2" -r '.[] | select(.publicIPAddressID==$var2) | .id')

az network cross-region-lb address-pool address add \
  --frontend-ip-address ${lb1_frontendip} \
  --lb-name ${glb} \
  --name "${aks1}_lb" \
  --pool-name kubernetes_lbs \
  --resource-group ${rG} --no-wait --only-show-errors

az network cross-region-lb address-pool address add \
  --frontend-ip-address ${lb2_frontendip} \
  --lb-name ${glb} \
  --name "${aks2}_lb" \
  --pool-name kubernetes_lbs \
  --resource-group ${rG} --no-wait --only-show-errors


# Set GLB Rules
rule=$(az network lb rule list --lb-name kubernetes -g ${infra1_rG} --query '[].{frontendIPConfigurationID:frontendIPConfiguration.id, "frontendPort":frontendPort, protocol:protocol}' -o json  | jq --arg var1 "$lb1_frontendip" -r '[.[] | select(.frontendIPConfigurationID==$var1) | {frontendPort:.frontendPort, protocol:.protocol}]')

# Test value
# rule='[{"frontendPort":80,"protocol":"Tcp"},{"frontendPort":8000,"protocol":"Tcp"}]'

ruleNum=$(echo $rule | jq length)

for ((i=0; i<${ruleNum}; i++))
do 
  frontendPort=$(echo $rule | jq -r '.['$i'] | .frontendPort')
  protocol=$(echo $rule | jq -r '.['$i'].protocol |= ascii_downcase | .['$i'].protocol')

  echo "Processing rule $((i+1)), in total of ${ruleNum}..."
  az network cross-region-lb rule create \
  --backend-port ${frontendPort} \
  --frontend-port ${frontendPort} \
  --lb-name ${glb} \
  --name "helloworld_$((i+1))" \
  --protocol ${protocol} \
  --resource-group ${rG} \
  --backend-pool-name kubernetes_lbs \
  --frontend-ip-name ${glb_ip} \
  --enable-floating-ip true --no-wait
done


echo "Deployment completed. The Global loadbalancer IP is: ${glb_ip_address}. Try accessing it from different location with different ACI instances."
echo "Creating two ACI instances for testing now..."
az container create -n ${aks1} -g ${rG} -l ${aks1_region} \
--image quay.io/curl/curl:latest -o none --command-line "sleep infinity"
az container create -n ${aks2} -g ${rG} -l ${aks2_region} \
--image quay.io/curl/curl:latest -o none --command-line "sleep infinity"

echo "ACI instances deployment is completed."
echo "Trying to access Global loadbalancer from 1st ACI..."
az container exec -n ${aks1} -g ${rG} \
--exec-command "curl http://ip-api.com/line/?fields=country"
az container exec -n ${aks1} -g ${rG} \
--exec-command "curl ${glb_ip_address}"

echo "Trying to access Global loadbalancer from 2nd ACI..."
az container exec -n ${aks2} -g ${rG} \
--exec-command "curl http://ip-api.com/line/?fields=country"
 az container exec -n ${aks2} -g ${rG} \
--exec-command "curl ${glb_ip_address}"

# Clean resources
echo 'Demo completed. Press "y" to clean resources after you tested it out.'
az group delete -n ${rG} --no-wait
