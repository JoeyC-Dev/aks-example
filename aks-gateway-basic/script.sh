#!/bin/bash
# Demo: Create an unmanaged gateway controller in AKS with NGINX Gateway Fabric
# https://blog.joeyc.dev/posts/aks-gateway-basic/

az extension add -n aks-preview

# Demo set-up
## Basic parameter

ranChar=$(tr -dc 0-9 < /dev/urandom | head -c 6)
rG=aks-${ranChar}
aks=aks-${ranChar}
vnet=aks-vnet
location=southeastasia


echo "Your resource group will be: ${rG}"
az group create -n ${rG} -l ${location} -o none

## Preparing VNet
az network vnet create -g ${rG} -n ${vnet} --address-prefixes ['10.208.0.0/16','10.209.0.0/16'] -o none 
az network vnet subnet create -n akssubnet -g ${rG} --vnet-name ${vnet} --address-prefixes 10.208.0.0/25 -o none --no-wait

vnetId=$(az resource list -n ${vnet} -g ${rG} \
    --resource-type Microsoft.Network/virtualNetworks \
    --query [0].id -o tsv)

## Create AKS
az aks create -n ${aks} -g ${rG} \
    --no-ssh-key -o none \
    --nodepool-name agentpool --enable-blob-driver \
    --node-os-upgrade-channel None \
    --node-count 1 \
    --node-vm-size Standard_B2s \
    --network-plugin azure \
    --vnet-subnet-id ${vnetId}/subnets/akssubnet

az aks get-credentials -n ${aks} -g ${rG}

## Install Gateway API/Nginx Gateway Fabric
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml

helm upgrade --install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric --create-namespace -n nginx-gateway \
  -f - <<EOF
nginx:
  pod:
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: kubernetes.azure.com/cluster
                  operator: Exists
                - key: type
                  operator: NotIn
                  values:
                    - virtual-kubelet
                - key: kubernetes.io/os
                  operator: In
                  values:
                    - linux
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
                - key: kubernetes.azure.com/mode
                  operator: In
                  values:
                    - user
nginxGateway:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: kubernetes.azure.com/cluster
                operator: Exists
              - key: type
                operator: NotIn
                values:
                  - virtual-kubelet
              - key: kubernetes.io/os
                operator: In
                values:
                  - linux
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: kubernetes.azure.com/mode
                operator: In
                values:
                  - user
certGenerator:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: kubernetes.azure.com/cluster
                operator: Exists
              - key: type
                operator: NotIn
                values:
                  - virtual-kubelet
              - key: kubernetes.io/os
                operator: In
                values:
                  - linux
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: kubernetes.azure.com/mode
                operator: In
                values:
                  - user
EOF

# Gateway Demo
## Deploy application
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: default-service-and-gateway
  labels:
    app.kubernetes.io/part-of: default-service
    app.kubernetes.io/component: gateway-api
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: service-one
  namespace: default-service-and-gateway
  labels:
    app.kubernetes.io/part-of: default-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: service-one
      app.kubernetes.io/part-of: default-service
  template:
    metadata:
      labels:
        app.kubernetes.io/name: service-one
        app.kubernetes.io/part-of: default-service
    spec:
      containers:
      - name: service-one
        image: mcr.microsoft.com/azuredocs/aks-helloworld:v1
        ports:
        - containerPort: 80
        env:
        - name: TITLE
          value: "Welcome to AKS Default Service Page"
---
apiVersion: v1
kind: Service
metadata:
  name: service-one
  namespace: default-service-and-gateway
  labels:
    app.kubernetes.io/part-of: default-service
spec:
  type: ClusterIP
  ports:
  - port: 80
    protocol: TCP
    name: http
  selector:
    app.kubernetes.io/name: service-one
    app.kubernetes.io/part-of: default-service
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: external-service
  labels:
    app.kubernetes.io/part-of: external-service
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: service-two
  namespace: external-service
  labels:
    app.kubernetes.io/part-of: external-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: service-two
      app.kubernetes.io/part-of: external-service
  template:
    metadata:
      labels:
        app.kubernetes.io/name: service-two
        app.kubernetes.io/part-of: external-service
    spec:
      containers:
      - name: service-two
        image: mcr.microsoft.com/azuredocs/aks-helloworld:v1
        ports:
        - containerPort: 80
        env:
        - name: TITLE
          value: "Welcome to AKS External Service Page"
---
apiVersion: v1
kind: Service
metadata:
  name: service-two
  namespace: external-service
  labels:
    app.kubernetes.io/part-of: external-service
spec:
  type: ClusterIP
  ports:
  - port: 80
    protocol: TCP
    name: http
  selector:
    app.kubernetes.io/name: service-two
    app.kubernetes.io/part-of: external-service
EOF

## Deploy Gateway
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: the-sole-unique-gateway
  namespace: default-service-and-gateway
  labels:
    app.kubernetes.io/component: gateway-api
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: "*.sslip.io"
  infrastructure:
    # Uncomment below if you prefer internal load balancer
    # annotations:
    #   service.beta.kubernetes.io/azure-load-balancer-internal: 'true'
    labels:
      app.kubernetes.io/part-of: gateway-api
EOF

while true; do
    result=$(kubectl get gateway the-sole-unique-gateway -n default-service-and-gateway -o jsonpath='{.status.addresses[0].value}')
    
    if [ -z "$result" ]; then
        echo "Result is null, retrying in 10 seconds..."
        sleep 10
    else
        GatewayIP=${result}
        break
    fi
done

routeDomain=${GatewayIP}.sslip.io

cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: service-one
  namespace: default-service-and-gateway
  labels:
    app.kubernetes.io/part-of: default-service
    app.kubernetes.io/component: gateway-api
spec:
  parentRefs:
  - name: the-sole-unique-gateway
    sectionName: http
  hostnames:
  - ${routeDomain}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /default
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - name: service-one
      namespace: default-service-and-gateway
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: service-two
  namespace: default-service-and-gateway
  labels:
    app.kubernetes.io/part-of: external-service
    app.kubernetes.io/component: gateway-api
spec:
  parentRefs:
  - name: the-sole-unique-gateway
    sectionName: http
  hostnames:
  - ${routeDomain}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /external
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - name: service-two
      namespace: external-service
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: service-one-static
  namespace: default-service-and-gateway
  labels:
    app.kubernetes.io/part-of: default-service
    app.kubernetes.io/component: gateway-api
spec:
  parentRefs:
  - name: the-sole-unique-gateway
    sectionName: http
  hostnames:
  - ${routeDomain}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /static
    backendRefs:
    - name: service-one
      namespace: default-service-and-gateway
      port: 80
EOF

cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: external-service-reference
  namespace: external-service
  labels:
    app.kubernetes.io/part-of: external-service
    app.kubernetes.io/component: gateway-api
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: default-service-and-gateway
  to:
  - group: ""
    kind: Service
    name: service-two
EOF

## Test traffic
sleep 30;

curl -s http://${routeDomain}/default | grep "Default Service Page</div>"
curl -s http://${routeDomain}/external | grep "External Service Page</div>"


# TLS configuration (cert-manager)
## Cert-manager installation
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager --create-namespace --namespace cert-manager \
  --set crds.enabled=true \
  --set config.enableGatewayAPI=true

## Re-configure Gateway
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: the-sole-unique-gateway
  namespace: default-service-and-gateway
  labels:
    app.kubernetes.io/component: gateway-api
  annotations:
    cert-manager.io/issuer: domain-cert-issuer
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    # Below will overwrite "*.sslip.io" with specific doamin
    # for requesting certificate
    hostname: ${routeDomain}
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchExpressions:
          - key: app.kubernetes.io/component
            operator: In
            values:
            - gateway-api
            - cert-issuer
  - name: https
    port: 443
    protocol: HTTPS
    hostname: ${routeDomain}
    tls:
      mode: Terminate
      certificateRefs:
      - name: domain-cert-secret
        namespace: cert-issuer
        kind: Secret
        group: ""
  infrastructure:
    labels:
      app.kubernetes.io/part-of: gateway-api
EOF

## Configure cert-manager
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: cert-issuer
  labels:
    app.kubernetes.io/component: cert-issuer
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: domain-cert-issuer
  namespace: cert-issuer
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-acme-secret
    solvers:
    - http01:
        gatewayHTTPRoute:
          parentRefs:
          - name: the-sole-unique-gateway
            namespace: default-service-and-gateway
            kind: Gateway
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: domain-cert
  namespace: cert-issuer
spec:
  issuerRef:
    name: domain-cert-issuer
  dnsNames:
  - ${routeDomain}
  privateKey:
    algorithm: ECDSA
    encoding: PKCS1
    size: 256
  secretName: domain-cert-secret
  secretTemplate:
    labels:
      app.kubernetes.io/component: cert-issuer
EOF

## Allow cross-namespace reference
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: domain-cert-reference
  namespace: cert-issuer
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: Gateway
    namespace: default-service-and-gateway
  to:
  - group: ""
    kind: Secret
    name: domain-cert-secret
EOF

## Configure HTTPRoute for HTTPS
kubectl patch httproute service-one \
  -n default-service-and-gateway \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/parentRefs/-", "value": {"name": "the-sole-unique-gateway", "sectionName": "https"}}]'

kubectl patch httproute service-two \
  -n default-service-and-gateway \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/parentRefs/-", "value": {"name": "the-sole-unique-gateway", "sectionName": "https"}}]'

kubectl patch httproute service-one-static \
  -n default-service-and-gateway \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/parentRefs/-", "value": {"name": "the-sole-unique-gateway", "sectionName": "https"}}]'

while true; do
    sleep 30;
    result=$(kubectl get secret domain-cert-secret -n cert-issuer)
    
    if [ -z "$result" ]; then
        echo "Certificate is not generated, retrying in 10 seconds..."
        sleep 10
    else
        break
    fi
done

## Test traffic
curl -s https://${routeDomain}/default | grep "Default Service Page</div>"
curl -s https://${routeDomain}/external | grep "External Service Page</div>"


# TLS configuration (Secret Store CSI Driver)
## Create certificate
tempDir=$(mktemp -d) && cd $tempDir

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout private.key -out certificate.pem -days 30 -nodes \
  -subj "/CN=${routeDomain}" -addext "subjectAltName=DNS:${routeDomain}"

openssl pkcs12 -export -in certificate.pem -passout pass: \
  -inkey private.key -out certificate.pfx

## Create Key Vault
kv=akskv${ranChar}

az keyvault create -n ${kv} -g ${rG} \
  --enable-rbac-authorization true -o none

kvId=$(az resource list -n ${kv} -g ${rG} \
  --resource-type Microsoft.KeyVault/vaults \
  --query [0].id -o tsv)
kvUri=$(az keyvault show -n ${kv} -g ${rG} \
  --query properties.vaultUri -o tsv)

userObjectId=$(az ad signed-in-user show --query id -o tsv)

az role assignment create --role "Key Vault Certificates Officer" \
  --assignee-object-id ${userObjectId} -o none \
  --scope ${kvId} --assignee-principal-type User

sleep 60; 
az keyvault certificate import --vault-name ${kv} \
  -n www-cert -f certificate.pfx -o none

## Configure Secret Store CSI driver
az aks enable-addons --addons azure-keyvault-secrets-provider \
  -o none -n ${aks} -g ${rG}

akvspObjectId=$(az aks show -n ${aks} -g ${rG} -o tsv \
  --query addonProfiles.azureKeyvaultSecretsProvider.identity.objectId)
akvspClientId=$(az aks show -n ${aks} -g ${rG} -o tsv \
  --query addonProfiles.azureKeyvaultSecretsProvider.identity.clientId)

az role assignment create --role "Key Vault Certificate User" \
  --assignee-object-id ${akvspObjectId} -o none \
  --scope ${kvId} --assignee-principal-type ServicePrincipal

tenantId=$(az account list --query "[?isDefault].tenantId | [0]" --output tsv)

sleep 60;

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: certificate
  labels:
    app.kubernetes.io/component: certificate
EOF

cat <<EOF | kubectl apply -f -
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: www-cert
  namespace: certificate
spec:
  provider: azure
  secretObjects:
    - secretName: www-cert-secret
      type: kubernetes.io/tls
      data: 
        - objectName: www-cert
          key: tls.key
        - objectName: www-cert
          key: tls.crt
  parameters:
    useVMManagedIdentity: "true"
    userAssignedIdentityID: ${akvspClientId}
    keyvaultName: ${kv}
    objects: |
      array:
        - |
          objectName: www-cert
          objectType: secret
    tenantId: ${tenantId}
EOF

## Configure dummy Pod
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: www-cert-dummy
  namespace: certificate
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: azure-secretprovider-dummy
  template:
    metadata:
      labels:
        app.kubernetes.io/name: azure-secretprovider-dummy
    spec:
      priorityClassName: system-node-critical
      affinity:
        podAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app.kubernetes.io/instance
                      operator: In
                      values:
                        - ngf
                topologyKey: "kubernetes.io/hostname"
      containers:
        - name: dummy-pod
          image: busybox
          command: ["sleep", "infinity"] 
          volumeMounts:
          - name: secrets-store-inline
            readOnly: true
            mountPath: /mnt/secrets-store
      volumes:
      - name: secrets-store-inline
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: www-cert
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
EOF

## Enable auto rotation
az aks addon update -n ${aks} -g ${rG} -o none \
  --addon azure-keyvault-secrets-provider --enable-secret-rotation

## Allow cross-namespace reference
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: domain-cert-reference
  namespace: certificate
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: Gateway
    namespace: default-service-and-gateway
  to:
  - group: ""
    kind: Secret
    name: www-cert-secret
EOF

## Configure Gateway
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: the-sole-unique-gateway
  namespace: default-service-and-gateway
  labels:
    app.kubernetes.io/component: gateway-api
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: ${routeDomain}
  - name: https
    port: 443
    protocol: HTTPS
    hostname: ${routeDomain}
    tls:
      mode: Terminate
      certificateRefs:
      - name: www-cert-secret
        namespace: certificate
        kind: Secret
        group: ""
  infrastructure:
    labels:
      app.kubernetes.io/part-of: gateway-api
EOF


## Test traffic
sleep 15;

curl -s -k https://${routeDomain}/default | grep "Default Service Page</div>"
curl -s -k https://${routeDomain}/external | grep "External Service Page</div>"

# Clean resources
echo 'Demo completed. Press "y" to clean resources after you tested it out.'
az group delete -n ${rG} --no-wait
