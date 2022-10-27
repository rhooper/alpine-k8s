#!/usr/bin/env bash

# Prerequisite
# Make sure you set secret environment variables in CI
# DOCKER_USERNAME
# DOCKER_PASSWORD

# set -ex

set -e

build() {
  GREP=grep

  if [[ "$(uname -s)" == "Darwin" ]]; then
    GREP=$(which ggrep) || brew install grep && GREP=$(which ggrep)
  fi

  # helm latest
  helm=$(curl -s https://github.com/helm/helm/releases)
  helm=$(echo $helm\" | ${GREP} -oP '(?<=tag\/v)[0-9][^"]*'|grep -v \-|sort -Vr|head -1)
  echo "helm version is $helm"

  # jq 1.6
  DEBIAN_FRONTEND=noninteractive
  #sudo apt-get update && sudo apt-get -q -y install jq
  if [[ "$(uname -s)" == "Linux" ]] && [ ! -x ./jq ]; then
    curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o jq
    chmod +x jq
    PATH=".:$PATH"
  fi

  # kustomize latest
  kustomize_release=$(curl -s https://api.github.com/repos/kubernetes-sigs/kustomize/releases | jq -r '.[].tag_name | select(contains("kustomize"))' \
    | sort -rV | head -n 1)
  kustomize_version=$(basename ${kustomize_release})
  echo "kustomize version is $kustomize_version"

  # kubeseal latest
  kubeseal_version=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases | jq -r '.[].tag_name | select(startswith("v"))' \
    | sort -rV | head -n 1 |sed 's/v//')
  echo "kubeseal version is $kubeseal_version"

  buildx_extra_args=()

  if [[ "$CIRCLE_BRANCH" == "master" ]]; then
    docker login -u $DOCKER_USERNAME -p $DOCKER_PASSWORD
    buildx_extra_args+=("--push")
  fi

  docker buildx rm alpine-k8s || true
  docker buildx create --name alpine-k8s --use
  docker buildx build --no-cache=true --platform linux/arm64,linux/amd64 \
    --build-arg KUBECTL_VERSION=${tag} \
    --build-arg HELM_VERSION=${helm} \
    --build-arg KUSTOMIZE_VERSION=${kustomize_version} \
    --build-arg KUBESEAL_VERSION=${kubeseal_version} \
    -t ${image}:${tag} ${buildx_extra_args[@]} .
  docker buildx rm alpine-k8s

  # run test
  echo "Detected Helm3+"
  version=$(docker run --rm ${image}:${tag} helm version)
  # version.BuildInfo{Version:"v3.6.3", GitCommit:"d506314abfb5d21419df8c7e7e68012379db2354", GitTreeState:"clean", GoVersion:"go1.16.5"}

  version=$(echo ${version}| awk -F \" '{print $2}')
  if [ "${version}" == "v${helm}" ]; then
    echo "matched"
  else
    echo "unmatched"
    exit
  fi


}

image="alpine/k8s"
curl -s https://kubernetes.io/releases/ > release.html

docker run -ti --rm -v $(pwd):/app bwits/html2txt  /app/release.html /app/release.txt
awk -F "[: ]" '/released:/{print $3}' release.txt | while read tag
do
  echo ${tag}
  status=$(curl -sL https://hub.docker.com/v2/repositories/${image}/tags/${tag})
  echo $status
  if [[ ( "${status}" =~ "not found" ) || ( ${REBUILD} == "true" ) ]]; then
     build
  fi
done
