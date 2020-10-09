#!/bin/bash

set -o errexit # Bail out on any error

if [[ ! -x "$(command -v kubectl)" ]]; then
    echo "kubectl not found"
    exit 1
fi

if [[ ! -x "$(command -v helm)" ]]; then
    echo "helm not found"
    exit 1
fi

REPO_URL="git@github.com:wataruian/gitops-istio.git"
REPO_GIT_INIT_PATHS="istio"
REPO_BRANCH="master"
REPO_ROOT="$(git rev-parse --show-toplevel)"
TEMP="${REPO_ROOT}/temp"
fluxNamespace="flux"
istioNamespace="istio-system"
fluxCDChartUrl="https://charts.fluxcd.io"
helmOperatorCrdUrl="https://raw.githubusercontent.com/fluxcd/helm-operator/master/deploy/crds.yaml"

#kubectl delete namespace ${fluxNamespace} || true
#kubectl delete clusterrole flux || true
#kubectl delete clusterrolebinding flux || true
#kubectl delete clusterrole helm-operator || true
#kubectl delete clusterrolebinding helm-operator || true

rm -rf ${TEMP} && mkdir ${TEMP}

helm repo add fluxcd ${fluxCDChartUrl}

echo ">>> Installing Flux for ${REPO_URL} only watching istio paths"
kubectl create namespace ${fluxNamespace} || true
helm upgrade -i flux fluxcd/flux --wait \
--set git.url=${REPO_URL} \
--set git.branch=${REPO_BRANCH} \
--set git.path=${REPO_GIT_INIT_PATHS} \
--set git.pollInterval=1m \
--set registry.pollInterval=1m \
--set sync.state=secret \
--set syncGarbageCollection.enabled=true \
--namespace ${fluxNamespace}

echo ">>> Installing Helm Operator"
kubectl apply -f ${helmOperatorCrdUrl}
helm upgrade -i helm-operator fluxcd/helm-operator --wait \
--set git.ssh.secretName=flux-git-deploy \
--set helm.versions=v3 \
--namespace ${fluxNamespace}

echo ">>> GitHub deploy key"
kubectl -n ${fluxNamespace} logs deployment/flux | grep identity.pub | cut -d '"' -f2

# wait until flux is able to sync with repo
echo ">>> Waiting on user to add above deploy key to Github with write access"
until kubectl logs -n ${fluxNamespace} deployment/flux | grep event=refreshed
do
  sleep 10
done
echo ">>> Github deploy key is ready"

# wait until sidecar injector webhook is ready before enabled prod namespace on flux
echo ">>> Waiting for istiod to start"
deployment=$(kubectl get deployments -n "$istioNamespace" istiod -o json | jq '.')
if [[ -z "$deployment" || "$deployment" == null ]]; then
  echo "Cannot find deployment: istiod"
  exit 1
fi

deploymentName=$(echo "$deployment" | jq -r '.metadata.name')
appName=$(echo "$deployment" | jq -r '.metadata.labels.app')

pods=$(kubectl get pods -n "$istioNamespace" -l "app=$appName" -o json | jq '.items')
for row in $(echo "${pods}" | jq -r '.[] | @base64'); do
   _jq() {
    echo ${row} | base64 --decode | jq -r ${1}
  }

  podName=$(_jq '.metadata.name')
  echo "Checking Pod Availability: $podName"
  ready="False"
  while [[ "$ready" != "True" ]]; do
    ready=$(kubectl get pods -n "$istioNamespace" "$podName" -o json | jq \
    '.status.conditions[] | select(.type == "Ready") | .status' | tr -d '"')

    echo "Availability: $ready"
    sleep 5
  done
done
echo ">>> Istio control plane is ready"

echo ">>> Configuring Flux for ${REPO_URL}"
helm upgrade -i flux fluxcd/flux --wait \
--set git.url=${REPO_URL} \
--set git.branch=${REPO_BRANCH} \
--set git.path="" \
--set git.pollInterval=1m \
--set registry.pollInterval=1m \
--set sync.state=secret \
--set syncGarbageCollection.enabled=true \
--namespace ${fluxNamespace}

echo ">>> Cluster bootstrap done!"