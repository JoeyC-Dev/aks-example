This script is a demonstration to show how to build an AKS with keda-http-addon, and how it performs when under stress testing.  
  
Link: https://blog.joeyc.dev/posts/aks-gateway-basic/  
  
This script will create:  
- One AKS instance
- One Load Balancer

> [!NOTE]
> This script will use `sslip.io` as external ip-to-domain service in Gateway for routing and generating certificate, which is not under control.  