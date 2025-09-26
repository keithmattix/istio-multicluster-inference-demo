#!/bin/bash


set -euo pipefail

REPO=istio
REPO_URL=https://github.com/istio/istio.git
REPO_DIR=""
TAG=$(curl https://storage.googleapis.com/istio-build/dev/1.28-dev)

function setup_remote_secrets() {
  echo "Setting up remote secrets in cluster $1 for remote cluster $2"
  CTX_LOCAL_CLUSTER=kind-"$1"
  CTX_REMOTE_CLUSTER=kind-"$2"

  # Get the IP address of the API server for the remote cluster
  CONTAINER_NAME=$(kind get nodes -n $2)
  SERVER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME")
  echo "Remote cluster API server IP: $SERVER_IP"

  pushd "$REPO_DIR"
  go run ./istioctl/cmd/istioctl create-remote-secret \
  --context="${CTX_REMOTE_CLUSTER}" \
  --name="$2" --server https://$SERVER_IP:6443 | \
  kubectl apply --context="${CTX_LOCAL_CLUSTER}" -f -
  popd
}

function configure_istio_inference() {
  echo "Configuring Istio Inference in context: $1"

  # Add DR to allow one-way (insecure TLS to the vllm-llama3-8b-instruct EPP)
  kubectl apply --context=$1 -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/main/config/manifests/gateway/istio/destination-rule.yaml
  # Now do the same for the vllm-gpt5-oss EPP
  kubectl apply --context=$1 -f ./gpt5-oss-epp-dr.yaml

  # Create an Istio inference Gateway
  kubectl apply --context=$1 -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/main/config/manifests/gateway/istio/gateway.yaml

  # Install the Body Based Router (BBR) and configure Istio to use it via EnvoyFilter
  helm install body-based-router --kube-context=$1 --set provider.name=istio --version v1.0.0 oci://registry.k8s.io/gateway-api-inference-extension/charts/body-based-routing

  # Now install the HTTPRoute to route requests to the appropriate EPP based on the headers set by the BBR
  kubectl apply --context=$1 -f ./httproute.yaml
}

function setup_istio() {
  echo "Setting up Istio in context: $1"
  CTX_CLUSTER=${$1#kind-}
  pushd "$REPO_DIR"
  go run ./istioctl/cmd/istioctl install -y --context=$1 --set tag=$TAG --set hub=gcr.io/istio-testing --set values.pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true \
  --set values.global.multiCluster.clusterName=$CTX_CLUSTER
  popd
}

function setup_inference_extension() {
  echo "Setting up Inference Extension in context: $1"

  # Install the Gateway API CRDs
  kubectl apply  --context=$1 -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
  # Deploy vLLM simulation deployments - one for Llama and one for GPT5-OSS
  kubectl apply  --context=$1 -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/main/config/manifests/vllm/sim-deployment.yaml
  kubectl apply  --context=$1 -f ./vllm-gpt5-oss-sim-deployment.yaml

  # Install the latest Inference Extension Gateway API CRDs
  kubectl apply  --context=$1 -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/latest/download/manifests.yaml
  # The extension deploys both alpha and v1 CRDs, so we need to clean up the alpha ones to avoid conflicts in the Istio controller
  kubectl delete --context=$1 customresourcedefinition.apiextensions.k8s.io/inferencepools.inference.networking.x-k8s.io --ignore-not-found

  export GATEWAY_PROVIDER=none

  # Deploy the inferencepools and EPP for Llama 3 8B Instruct
  helm install vllm-llama3-8b-instruct --kube-context=$1  \
  --set inferencePool.modelServers.matchLabels.app=vllm-llama3-8b-instruct \
  --set provider.name=$GATEWAY_PROVIDER \
  --version v1.0.0 \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool

  # Deploy the inferencepools and EPP for GPT5-OSS
  helm install vllm-gpt5-oss --kube-context=$1  \
  --set inferencePool.modelServers.matchLabels.app=vllm-gpt5-oss \
  --set provider.name=$GATEWAY_PROVIDER \
  --version v1.0.0 \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool
}

if [ "$(basename "$PWD")" = "$REPO" ]; then
  echo "Using current directory as $REPO"
  REPO_DIR="$PWD"
elif [ -d "./$REPO" ]; then
  echo "Entering ./$REPO"
  REPO_DIR="./$REPO"
  pushd "$REPO_DIR"
elif [ -d "../$REPO" ]; then
  echo "Entering ../$REPO"
  REPO_DIR="../$REPO"
  pushd "$REPO_DIR"
else
  if ! command -v git >/dev/null 2>&1; then
    echo "git is required but not installed" >&2
    exit 1
  fi
  echo "Cloning $REPO into ./ $REPO"
  git clone "$REPO_URL" "$REPO"
  REPO_DIR="./$REPO"
  pushd "$REPO"
fi

if [ ! -f ./prow/integ-suite-kind.sh ]; then
  echo "Expected ./prow/integ-suite-kind.sh not found in $(pwd)" >&2
  exit 1
fi

# We're on master which at this point in time has v1 InferencePool support
./prow/integ-suite-kind.sh --skip-cleanup --topology MULTICLUSTER --topology-config ../istio-multicluster-inference-demo/multicluster-single-network.json
popd

KIND_CLUSTER1=primary-1
KIND_CLUSTER2=primary-2
CTX_CLUSTER1=kind-$KIND_CLUSTER1
CTX_CLUSTER2=kind-$KIND_CLUSTER2

for CTX_CLUSTER in $CTX_CLUSTER1 $CTX_CLUSTER2; do
  setup_istio "$CTX_CLUSTER"
  setup_inference_extension "$CTX_CLUSTER"
  configure_istio_inference "$CTX_CLUSTER"
done

# Now set up remote secrets in both clusters
setup_remote_secrets "$KIND_CLUSTER1" "$KIND_CLUSTER2"
setup_remote_secrets "$KIND_CLUSTER2" "$KIND_CLUSTER1"


# Now test the setup by using curl to send requests to the gateway in cluster1:
kubectl config use-context $CTX_CLUSTER1
IP=$(kubectl get gateway/inference-gateway -o jsonpath='{.status.addresses[0].value}'); PORT=80
curl -X POST -i ${IP}:${PORT}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "food-review-2",
    "messages": [{"role": "user", "content": "What is the color of the sky?"}],
    "max_tokens": 100,
    "temperature": 0
  }'
