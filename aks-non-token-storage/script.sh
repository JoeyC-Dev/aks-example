#!/bin/bash
# https://blog.joeyc.dev/posts/aks-non-token-storage/

check_pod_online () {
  while [[ $(kubectl get po $1 -n $2 -o json | jq -r \
  'if .status.phase != "Running" then false else .status.containerStatuses[] | select(.name == "demo").started end') != "true" ]]; \
  do echo "Pending Pod to be online..."; sleep 5; done; echo "Pod is online."
}

az extension add -n k8s-extension

# Demo set-up
## Basic parameter
ranChar=$(tr -dc a-z0-9 < /dev/urandom | head -c 8)
rG=aks-${ranChar}
aks=aks-${ranChar}
vnet=aks-vnet
nodeCount=3 # Three nodes are required for Azure Container Storage extension
location=southeastasia

echo "Your resource group will be: ${rG}"
az group create -n ${rG} -l ${location} -o none

## Preparing VNet
az network vnet create -g ${rG} -n ${vnet} \
--address-prefixes 10.208.0.0/12 -o none 
az network vnet subnet create -n nodesubnet -o none --no-wait \
--vnet-name ${vnet} -g ${rG} --address-prefixes 10.208.0.0/24
az network vnet subnet create -n podsubnet -o none \
-g ${rG} --vnet-name ${vnet} --address-prefixes 10.209.0.0/23

## Add Service Endpoint for further use
az network vnet subnet update -n nodesubnet -o none --no-wait \
--vnet-name ${vnet} -g ${rG} --service-endpoints Microsoft.Storage

vnetId=$(az resource list -n ${vnet} -g ${rG} \
--resource-type Microsoft.Network/virtualNetworks \
--query [0].id -o tsv)

## Create AKS
echo "Creating AKS..."
az aks create -n ${aks} -g ${rG} \
--no-ssh-key -o none --enable-blob-driver \
--nodepool-name nodepool \
--node-os-upgrade-channel None \
--node-count ${nodeCount} \
--node-vm-size Standard_A4_v2 \
--network-plugin azure \
--vnet-subnet-id ${vnetId}/subnets/nodesubnet \
--pod-subnet-id ${vnetId}/subnets/podsubnet

az aks get-credentials -n ${aks} -g ${rG}

## Get object/client ID of AKS kubelet identity
aksKubeletClientId=$(az aks show -n ${aks} -g ${rG} -o tsv \
--query identityProfile.kubeletidentity.clientId)
aksKubeletObjectId=$(az aks show -n ${aks} -g ${rG} -o tsv \
--query identityProfile.kubeletidentity.objectId)

## Get object ID of AKS identity
aksIdentityId=$(az aks show -n ${aks} -g ${rG} \
--query identity.principalId -o tsv)

# Demonstration
## BlobFuse demo
### Create storage account
echo "Building BlobFuse demonstration..."
sa=blobfuse${ranChar}

az storage account create -n ${sa} -g ${rG} \
--kind StorageV2 -o none \
--sku Standard_LRS \
--allow-shared-key-access false

sleep 30; saId=$(az storage account show \
-n ${sa} -g ${rG} --query id -o tsv)

container=aks-container

az rest --method PUT -o none \
--url https://management.azure.com${saId}/blobServices/default/containers/${container}?api-version=2023-05-01 \
--body "{}"

### Role assignment
az role assignment create --role "Storage Blob Data Contributor" \
--assignee-object-id ${aksKubeletObjectId} -o none \
--scope ${saId}/blobServices/default/containers/${container} \
--assignee-principal-type ServicePrincipal

echo "Waiting 30 seconds to have role assignment being provisioned..."
sleep 30;

### Disable public access and allow access from AKS node subnet
az storage account update -n ${sa} -g ${rG} \
--default-action Deny -o none

az storage account network-rule add -n ${sa} -g ${rG} \
--vnet-name ${vnet} --subnet nodesubnet -o none

### Randomize volumeHandle ID
volUniqId=${sa}#${container}#$(tr -dc a-zA-Z0-9 < /dev/urandom | head -c 4)

### Deploying Kubernetes storage resources
cat <<EOF | kubectl apply -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: azureblob-fuse
provisioner: blob.csi.azure.com
parameters:
  skuName: Standard_LRS
reclaimPolicy: Delete
mountOptions:
  - '-o allow_other'
  - '--file-cache-timeout-in-seconds=120'
  - '--use-attr-cache=true'
  - '--cancel-list-on-mount-seconds=10'
  - '-o attr_timeout=120'
  - '-o entry_timeout=120'
  - '-o negative_timeout=120'
  - '--log-level=LOG_WARNING'
  - '--cache-size-mb=1000'
allowVolumeExpansion: true
volumeBindingMode: Immediate
---
apiVersion: v1
kind: PersistentVolume
metadata:
  annotations:
    pv.kubernetes.io/provisioned-by: blob.csi.azure.com
  name: pv-${sa}-${container}-blobfuse
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: azureblob-fuse
  mountOptions:
    - -o allow_other
    - --file-cache-timeout-in-seconds=120
  csi:
    driver: blob.csi.azure.com
    volumeHandle: ${volUniqId}
    volumeAttributes:
      resourceGroup: ${rG}
      storageAccount: ${sa}
      containerName: ${container}
      AzureStorageAuthType: msi
      AzureStorageIdentityClientID: ${aksKubeletClientId}
---
apiVersion: v1
kind: Namespace
metadata:
  name: blobfuse
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-${sa}-${container}-blobfuse
  namespace: blobfuse
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azureblob-fuse
  volumeName: pv-${sa}-${container}-blobfuse
  resources:
    requests:
      storage: 5Gi
EOF

echo "Mounting blob container into Pod..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: blobfuse-mount-${ranChar}-1
  namespace: blobfuse
spec:
  containers:
  - name: demo
    image: alpine
    command: ["/bin/sh"]
    args: ["-c", "while true; do cat /mnt/azure/text; sleep 5; done"]
    volumeMounts:
      - mountPath: /mnt/azure
        name: volume
        readOnly: false
  volumes:
   - name: volume
     persistentVolumeClaim:
       claimName: pvc-${sa}-${container}-blobfuse 
EOF

### Write the message to a file and check if it works after the Pod starts
check_pod_online blobfuse-mount-${ranChar}-1 blobfuse

echo "Writing files into blob container..."
echo 'Note that error message of "No such file or directory" is expected in the first line of output...'
kubectl exec blobfuse-mount-${ranChar}-1 -n blobfuse \
-- sh -c 'touch /mnt/azure/text; echo hello\! > /mnt/azure/text'

echo "Checking if the file is written..."
sleep 5; kubectl logs blobfuse-mount-${ranChar}-1 -n blobfuse

### Re-check if the file is written
echo "Check if other Pods can get the same file..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: blobfuse-mount-${ranChar}-2
  namespace: blobfuse
spec:
  containers:
  - name: demo
    image: alpine
    command: ["/bin/sh"]
    args: ["-c", "while true; do cat /mnt/azure/text; sleep 5; done"]
    volumeMounts:
      - mountPath: /mnt/azure
        name: volume
        readOnly: false
  volumes:
   - name: volume
     persistentVolumeClaim:
       claimName: pvc-${sa}-${container}-blobfuse 
EOF
sleep 20; kubectl logs blobfuse-mount-${ranChar}-2 -n blobfuse

printf "\nBlobFuse demonstration completed.\n"

## NFS in blob container demo
### Create storage account
echo "Building NFS in blob container demonstration..."
sa=blobnfs${ranChar}

az storage account create -n ${sa} -g ${rG} \
--kind StorageV2 --sku Standard_LRS \
--enable-hierarchical-namespace -o none \
--allow-shared-key-access false \
--enable-nfs-v3 --default-action Deny

sleep 30; saId=$(az storage account show \
-n ${sa} -g ${rG} --query id -o tsv)

container=aks-container

az rest --method PUT -o none \
--url https://management.azure.com${saId}/blobServices/default/containers/${container}?api-version=2023-05-01 \
--body "{}"

### Allow access from AKS node subnet
az storage account network-rule add -n ${sa} -g ${rG} \
--vnet-name ${vnet} --subnet nodesubnet -o none

### Randomize volumeHandle ID
volUniqId=${sa}#${container}#$(tr -dc a-zA-Z0-9 < /dev/urandom | head -c 4)

### Deploying Kubernetes storage resources
cat <<EOF | kubectl apply -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: azureblob-nfs
provisioner: blob.csi.azure.com
parameters:
  protocol: nfs
  skuName: Standard_LRS
reclaimPolicy: Delete
mountOptions:
  - nconnect=4  # Azure Linux node does not support nconnect option
allowVolumeExpansion: true
volumeBindingMode: Immediate
---
apiVersion: v1
kind: PersistentVolume
metadata:
  annotations:
    pv.kubernetes.io/provisioned-by: blob.csi.azure.com
  name: pv-${sa}-${container}-nfs
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: azureblob-nfs
  mountOptions:
    - nconnect=4  # Azure Linux node does not support nconnect option
  csi:
    driver: blob.csi.azure.com
    volumeHandle: ${volUniqId}
    volumeAttributes:
      resourceGroup: ${rG}
      storageAccount: ${sa}
      containerName: ${container}
      protocol: nfs
---
apiVersion: v1
kind: Namespace
metadata:
  name: nfs
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-${sa}-${container}-nfs
  namespace: nfs
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azureblob-nfs
  volumeName: pv-${sa}-${container}-nfs
  resources:
    requests:
      storage: 5Gi
EOF

echo "Mounting blob container into Pod..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nfs-mount-${ranChar}-1
  namespace: nfs
spec:
  containers:
  - name: demo
    image: alpine
    command: ["/bin/sh"]
    args: ["-c", "while true; do cat /mnt/azure/text; sleep 5; done"]
    volumeMounts:
      - mountPath: /mnt/azure
        name: volume
        readOnly: false
  volumes:
   - name: volume
     persistentVolumeClaim:
       claimName: pvc-${sa}-${container}-nfs
EOF

### Write the message to a file and check if it works after the Pod starts
check_pod_online nfs-mount-${ranChar}-1 nfs

echo "Writing files into blob container..."
echo 'Note that error message of "No such file or directory" is expected in the first line of output...'
kubectl exec nfs-mount-${ranChar}-1 -n nfs \
-- sh -c 'touch /mnt/azure/text; echo hello\! > /mnt/azure/text'

echo "Checking if the file is written..."
sleep 5; kubectl logs nfs-mount-${ranChar}-1 -n nfs

### Re-check if the file is written
echo "Check if other Pods can get the same file..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nfs-mount-${ranChar}-2
  namespace: nfs
spec:
  containers:
  - name: demo
    image: alpine
    command: ["/bin/sh"]
    args: ["-c", "while true; do cat /mnt/azure/text; sleep 5; done"]
    volumeMounts:
      - mountPath: /mnt/azure
        name: volume
        readOnly: false
  volumes:
   - name: volume
     persistentVolumeClaim:
       claimName: pvc-${sa}-${container}-nfs
EOF
sleep 20; kubectl logs nfs-mount-${ranChar}-2 -n nfs

printf "\nNFS in blob container demonstration completed.\n"

## NFS in fileshare demo
### Create storage account
echo "Building NFS in fileshare demonstration..."
sa=filesharenfs${ranChar}

### Secure transfer must be disabled to use NFS in Azure fileshare
az storage account create -n ${sa} -g ${rG} \
--kind FileStorage -o none \
--sku Premium_LRS --default-action Deny \
--allow-shared-key-access false  \
--https-only false

sleep 30; saId=$(az storage account show \
-n ${sa} -g ${rG} --query id -o tsv)

fileshare=aks-fileshare

az rest --method PUT -o none \
--url https://management.azure.com${saId}/fileServices/default/shares/${fileshare}?api-version=2023-05-01 \
--body "{'properties':{'enabledProtocols':'NFS'}}"

### Allow access from AKS node subnet
az storage account network-rule add -n ${sa} -g ${rG} \
--vnet-name ${vnet} --subnet nodesubnet -o none

### Randomize volumeHandle ID
volUniqId=${sa}#${fileshare}#$(tr -dc a-zA-Z0-9 < /dev/urandom | head -c 4)

### Deploying Kubernetes storage resources
cat <<EOF | kubectl apply -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: azurefile-premium-nfs
provisioner: file.csi.azure.com
parameters:
  protocol: nfs
  skuName: Premium_LRS
reclaimPolicy: Delete
mountOptions:
  - nconnect=4  # Azure Linux node does not support nconnect option
  - noresvport
  - actimeo=30
allowVolumeExpansion: true
volumeBindingMode: Immediate
---
apiVersion: v1
kind: PersistentVolume
metadata:
  annotations:
    pv.kubernetes.io/provisioned-by: file.csi.azure.com
  name: pv-${sa}-${fileshare}-nfs
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: azurefile-premium-nfs
  mountOptions:
    - nconnect=4  # Azure Linux node does not support nconnect option
    - noresvport
    - actimeo=30
  csi:
    driver: file.csi.azure.com
    volumeHandle: ${volUniqId}
    volumeAttributes:
      resourceGroup: ${rG}
      storageAccount: ${sa}
      shareName: ${fileshare}
      protocol: nfs
---
apiVersion: v1
kind: Namespace
metadata:
  name: fileshare
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-${sa}-${fileshare}-nfs
  namespace: fileshare
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azurefile-premium-nfs
  volumeName: pv-${sa}-${fileshare}-nfs
  resources:
    requests:
      storage: 5Gi
EOF

echo "Mounting fileshare into Pod..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nfs-mount-${ranChar}-1
  namespace: fileshare
spec:
  containers:
  - name: demo
    image: alpine
    command: ["/bin/sh"]
    args: ["-c", "while true; do cat /mnt/azure/text; sleep 5; done"]
    volumeMounts:
      - mountPath: /mnt/azure
        name: volume
        readOnly: false
  volumes:
   - name: volume
     persistentVolumeClaim:
       claimName: pvc-${sa}-${fileshare}-nfs
EOF

### Write the message to a file and check if it works after the Pod starts
check_pod_online nfs-mount-${ranChar}-1 fileshare

echo "Writing files into fileshare..."
echo 'Note that error message of "No such file or directory" is expected in the first line of output...'
kubectl exec nfs-mount-${ranChar}-1 -n fileshare \
-- sh -c 'touch /mnt/azure/text; echo hello\! > /mnt/azure/text'

echo "Checking if the file is written..."
sleep 5; kubectl logs nfs-mount-${ranChar}-1 -n fileshare

### Re-check if the file is written
echo "Check if other Pods can get the same file..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nfs-mount-${ranChar}-2
  namespace: fileshare
spec:
  containers:
  - name: demo
    image: alpine
    command: ["/bin/sh"]
    args: ["-c", "while true; do cat /mnt/azure/text; sleep 5; done"]
    volumeMounts:
      - mountPath: /mnt/azure
        name: volume
        readOnly: false
  volumes:
   - name: volume
     persistentVolumeClaim:
       claimName: pvc-${sa}-${fileshare}-nfs
EOF
sleep 20; kubectl logs nfs-mount-${ranChar}-2 -n fileshare

printf "\nNFS in fileshare demonstration completed.\n"

## Azure Disk demo
### Create storage account
echo "Building Azure Disk demonstration..."
disk=aks-disk-${ranChar}

az disk create -n ${disk} -g ${rG} \
--size-gb 10 --sku Standard_LRS -o none

diskId=$(az disk show \
-n ${disk} -g ${rG} --query id -o tsv)

### Role assignment
az role assignment create --role "Virtual Machine Contributor" \
--assignee-object-id ${aksIdentityId} -o none \
--scope ${diskId} --assignee-principal-type ServicePrincipal

echo "Waiting 300 seconds to have role assignment being provisioned..."
sleep 300;

### Deploying Kubernetes storage resources
cat <<EOF | kubectl apply -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: disk
provisioner: disk.csi.azure.com
parameters:
  skuName: Standard_LRS
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  annotations:
    pv.kubernetes.io/provisioned-by: disk.csi.azure.com
  name: pv-${disk}
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: disk
  csi:
    driver: disk.csi.azure.com
    volumeHandle: ${diskId}
    volumeAttributes:
      fsType: ext4
---
apiVersion: v1
kind: Namespace
metadata:
  name: disk
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-${disk}
  namespace: disk
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: disk
  volumeName: pv-${disk}
  resources:
    requests:
      storage: 5Gi
EOF

echo "Mounting Azure Disk into Pod..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: disk-mount-${ranChar}-1
  namespace: disk
spec:
  containers:
  - name: demo
    image: alpine
    command: ["/bin/sh"]
    args: ["-c", "while true; do cat /mnt/azure/text; sleep 5; done"]
    volumeMounts:
      - mountPath: /mnt/azure
        name: volume
        readOnly: false
  volumes:
   - name: volume
     persistentVolumeClaim:
       claimName: pvc-${disk}
EOF

### Write the message to a file and check if it works after the Pod starts
check_pod_online disk-mount-${ranChar}-1 disk

echo "Writing files into Azure Disk..."
echo 'Note that error message of "No such file or directory" is expected in the first line of output...'
kubectl exec disk-mount-${ranChar}-1 -n disk \
-- sh -c 'touch /mnt/azure/text; echo hello\! > /mnt/azure/text'

echo "Checking if the file is written..."
sleep 5; kubectl logs disk-mount-${ranChar}-1 -n disk

### Re-check if the file is written
echo "Check if other Pods can get the same file..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: disk-mount-${ranChar}-2
  namespace: disk
spec:
  containers:
  - name: demo
    image: alpine
    command: ["/bin/sh"]
    args: ["-c", "while true; do cat /mnt/azure/text; sleep 5; done"]
    volumeMounts:
      - mountPath: /mnt/azure
        name: volume
        readOnly: false
  volumes:
   - name: volume
     persistentVolumeClaim:
       claimName: pvc-${disk}
  nodeSelector:
    kubernetes.io/hostname: $(kubectl get po disk-mount-${ranChar}-1 -n disk -o jsonpath='{.spec.nodeName}')
EOF
sleep 20; kubectl logs disk-mount-${ranChar}-2 -n disk

printf "\nAzure Disk demonstration completed.\n"

## Azure Container Storage demo
### Installing ACS extension
echo "Building Azure Container Storage demonstration..."
echo "Installing Azure Container Storage extension. Be aware that this may take 15 minutes to install..."

az aks nodepool update -n nodepool -g ${rG} -o none \
--cluster-name ${aks} --labels "acstor.azure.com/io-engine=acstor"

az aks update -n ${aks} -g ${rG} -o none \
--enable-azure-container-storage ephemeralDisk \
--storage-pool-option Temp \
--ephemeral-disk-volume-type PersistentVolumeWithAnnotation

### Deploying Kubernetes storage resources
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: acs
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ephemeralpvc
  namespace: acs
  annotations:
    acstor.azure.com/accept-ephemeral-storage: "true"
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: acstor-ephemeraldisk-temp
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: acs-mount-${ranChar}-1
  namespace: acs
spec:
  containers:
  - name: demo
    image: alpine
    command: ["/bin/sh"]
    args: ["-c", "while true; do cat /mnt/azure/text; sleep 5; done"]
    volumeMounts:
      - mountPath: /mnt/azure
        name: volume
        readOnly: false
  volumes:
   - name: volume
     persistentVolumeClaim:
        claimName: ephemeralpvc
  nodeSelector:
    acstor.azure.com/io-engine: acstor
EOF

### Write the message to a file and check if it works after the Pod starts
check_pod_online acs-mount-${ranChar}-1 acs

echo "Writing files into Azure Disk..."
echo 'Note that error message of "No such file or directory" is expected in the first line of output...'
kubectl exec acs-mount-${ranChar}-1 -n acs \
-- sh -c 'touch /mnt/azure/text; echo hello\! > /mnt/azure/text'

echo "Checking if the file is written..."
sleep 5; kubectl logs acs-mount-${ranChar}-1 -n acs

### Re-check if the file is written
echo "Check if other Pods can get the same file..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: acs-mount-${ranChar}-2
  namespace: acs
spec:
  containers:
  - name: demo
    image: alpine
    command: ["/bin/sh"]
    args: ["-c", "while true; do cat /mnt/azure/text; sleep 5; done"]
    volumeMounts:
      - mountPath: /mnt/azure
        name: volume
        readOnly: false
  volumes:
   - name: volume
     persistentVolumeClaim:
        claimName: ephemeralpvc
  nodeSelector:
    kubernetes.io/hostname: $(kubectl get po acs-mount-${ranChar}-1 -n acs -o jsonpath='{.spec.nodeName}')
    acstor.azure.com/io-engine: acstor
EOF
sleep 20; kubectl logs acs-mount-${ranChar}-2 -n acs


# Clean resources
echo 'Demo completed. Press "y" to clean resources after you tested it out.'
az group delete -n ${rG} --no-wait