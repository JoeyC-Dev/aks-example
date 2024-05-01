#!/bin/bash
# Official walkthrough: https://github.com/kedacore/http-add-on/blob/main/docs/walkthrough.md

randomNum=$(echo $RANDOM)
rG=my-aks-keda-${randomNum}
aks=my-aks-keda-${randomNum}
loadTest=my-loadTest-${randomNum}
region=germanywestcentral

# Pre-check if command is installed
if ! command -v tr &> /dev/null
then
    echo 'The command "tr" could not be found'
    exit 1
fi
if ! command -v timeout &> /dev/null
then
    echo 'The command "timeout" could not be found'
    exit 1
fi
if ! command -v curl &> /dev/null
then
    echo 'The command "curl" could not be found'
    exit 1
fi
if ! command -v kubectl &> /dev/null
then
    echo 'The command "kubectl" could not be found'
    exit 1
fi

# Prompt confirmation pop-up
# https://stackoverflow.com/a/1885534/23507547
read -p "This script will use nip.io as external ip-to-domain service in Ingress for Load Testing. Continue? (Y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    [[ "$0" = "$BASH_SOURCE" ]] && exit 1 || return 1 
fi

# Create resource group
echo "Your resource group will be: ${rG}"
az group create -n ${rG} -l ${region} -o none

# Create AKS instance
echo "Creating AKS instance. It will take a long time: approximately 5 minutes..."
az aks create -n ${aks} -g ${rG} --node-count 2 --node-vm-size Standard_A4_v2 --enable-keda --enable-app-routing  -o none --no-ssh-key
az aks get-credentials -n ${aks} -g ${rG} --only-show-errors
 
# Install keda http-add-on
echo "Installing keda http-add-on..."
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install http-add-on kedacore/keda-add-ons-http --namespace kube-system
 
# Install example application with HTTPScaleObject
mkdir my-aks-keda-${randomNum}
git clone https://github.com/kedacore/http-add-on.git my-aks-keda-${randomNum}/http-add-on
helm install xkcd ./my-aks-keda-${randomNum}/http-add-on/examples/xkcd

# Patch ingressClassName 
kubectl patch ingress xkcd -p '{"spec":{"ingressClassName": "webapprouting.kubernetes.azure.com"}}'
 
# Patch svc externalName
kubectl patch svc xkcd-proxy -p '{"spec":{"externalName": "keda-add-ons-http-interceptor-proxy.kube-system"}}'
 
# Get Ingress IP
ip=$(kubectl get svc nginx -n app-routing-system -o=jsonpath='{.status.loadBalancer.ingress[0].ip}')
ipString=$(echo ${ip} | tr . -)
FQDN=${rG}-${ipString}.nip.io

# Replace with FQDN route + modify targetPendingRequests 
echo "The domain ${FQDN} will be used for ingress routing"
kubectl patch ingress xkcd --type=json \
  -p="[{\"op\": \"replace\", \"path\": \"/spec/rules/0/host\", \"value\":"${FQDN}"}]"
kubectl patch HTTPScaledObject xkcd --type=json \
  -p="[{\"op\": \"replace\", \"path\": \"/spec/hosts/0\", \"value\":"${FQDN}"}, {\"op\": \"replace\", \"path\": \"/spec/targetPendingRequests\", \"value\":"25"}]"


# Test output
echo "The following output is the example output from application:"
sleep 3; curl -H "Host: ${FQDN}" ${ip}/path1
echo ""

# Deploy Azure load testing
# Prompt confirmation pop-up
read -p "The Load Testing service will be deployed. Continue? (Y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    [[ "$0" = "$BASH_SOURCE" ]] && exit 1 || return 1 
fi

echo "Deploying Azure Load Testing for stress testing..."
az load create -n ${loadTest} -g ${rG} -o none

cat << EOF > ./my-aks-keda-${randomNum}/url_test.jmx
<?xml version="1.0" encoding="UTF-8"?>
<jmeterTestPlan version="1.2" properties="5.0" jmeter="5.6.3">
  <hashTree>
    <TestPlan guiclass="TestPlanGui" testname="Test Plan">
      <elementProp name="TestPlan.user_defined_variables" elementType="Arguments" guiclass="ArgumentsPanel" testclass="Arguments" testname="User Defined Variables">
        <collectionProp name="Arguments.arguments"/>
      </elementProp>
    </TestPlan>
    <hashTree>
      <kg.apc.jmeter.threads.UltimateThreadGroup guiclass="kg.apc.jmeter.threads.UltimateThreadGroupGui" testname="requestGroup1" enabled="true">
        <stringProp name="testclass">kg.apc.jmeter.threads.UltimateThreadGroup</stringProp>
        <elementProp name="ThreadGroup.main_controller" elementType="LoopController" guiclass="LoopControlPanel" testclass="LoopController">
          <stringProp name="LoopController.loops">\${__P(iterations,-1)}</stringProp>
          <stringProp name="testname">LoopController</stringProp>
          <boolProp name="LoopController.continue_forever">false</boolProp>
        </elementProp>
        <collectionProp name="ultimatethreadgroupdata">
          <collectionProp name="ThreadSchedule1">
            <stringProp name="threadsnum">120</stringProp>
            <stringProp name="initdelay">0</stringProp>
            <stringProp name="startime">60</stringProp>
            <stringProp name="holdload">1140</stringProp>
            <stringProp name="shutdown"></stringProp>
          </collectionProp>
        </collectionProp>
      </kg.apc.jmeter.threads.UltimateThreadGroup>
      <hashTree>
        <HTTPSamplerProxy guiclass="HttpTestSampleGui" testname="keda-http-addon-test">
          <elementProp name="HTTPsampler.Arguments" elementType="Arguments">
            <collectionProp name="Arguments.arguments"/>
          </elementProp>
          <stringProp name="HTTPSampler.implementation">HttpClient4</stringProp>
          <stringProp name="HTTPSampler.protocol">http</stringProp>
          <stringProp name="HTTPSampler.path">/path1</stringProp>
          <stringProp name="HTTPSampler.domain">${FQDN}</stringProp>
          <boolProp name="HTTPSampler.use_keepalive">true</boolProp>
          <boolProp name="HTTPSampler.follow_redirects">true</boolProp>
          <stringProp name="HTTPSampler.method">GET</stringProp>
          <elementProp name="HTTPSampler.header_manager" elementType="HeaderManager" guiclass="HeaderPanel" testname="HTTP HeaderManager">
            <collectionProp name="HeaderManager.headers"/>
          </elementProp>
        </HTTPSamplerProxy>
        <hashTree>
          <HeaderManager guiclass="HeaderPanel" testname="HTTP HeaderManager">
            <collectionProp reference="../../../HTTPSamplerProxy/elementProp[2]/collectionProp"/>
          </HeaderManager>
          <hashTree/>
        </hashTree>
      </hashTree>
    </hashTree>
  </hashTree>
</jmeterTestPlan>
EOF

az load test create --load-test-resource ${loadTest} -g ${rG} --test-id keda-http-addon-test --test-plan ./my-aks-keda-${randomNum}/url_test.jmx -o none
az load test-run create --load-test-resource ${loadTest}  -g ${rG} --test-id keda-http-addon-test --test-run-id $(date +"%Y%m%d%H%M%S")_${RANDOM} --no-wait

echo "Wait 60 seconds for test-run to be provisioned. The HPA monitor will automatically exit in 240 seconds after starting."
sleep 60; timeout 240 kubectl get hpa -w

# Clean resources
echo 'Demo completed. Press "y" to clean resources after you tested it out.'
az group delete -n ${rG} --no-wait
