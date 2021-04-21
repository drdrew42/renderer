#Deploy Renderer to Kubernetes
1. Install `kubectl`, the [official Kubernetes client](https://kubernetes.io/docs/tasks/tools/install-kubectl/). Use the most recent version of kubectl to ensure you are within one minor version of your cluster's Kubernetes version.
2. Install `doctl`, the official [DigitalOcean command-line tool](https://github.com/digitalocean/doctl), or other cloud platform-specific command-line tool.
3. Install [helm](https://helm.sh/docs/intro/install/), the kubernetes package manager.
4. Use your cloud provider's CLI tool to authenticate kubectl to your cluster.
5. Install the [Kubernetes metric server using helm](https://artifacthub.io/packages/helm/bitnami/metrics-server) onto your cluster.
6. Modify the included `Renderer.yml` and `Ingress.yml` files and use `kubectl apply -f <filename.yml>` to apply these configurations onto your cluster.
7. Set up a network Ingress by following this [DigitalOcean tutorial](https://www.digitalocean.com/community/tutorials/how-to-set-up-an-nginx-ingress-on-digitalocean-kubernetes-using-helm). As part of this, you will need to set up DNS records towards your cluster or load-balancer.
