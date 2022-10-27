#!/usr/bin/env bash

# Prerequisite
# Make sure you set secret environment variables in CI
# DOCKER_USERNAME
# DOCKER_PASSWORD

# set -ex

set -e

trap 'export -p' 0

GREP=grep

build() {

  # helm latest
  helm="$(curl -s https://api.github.com/repos/helm/helm/releases/latest | $JQ -r '.tag_name | .[1:]')"
  echo "helm version is $helm"

  # kustomize latest
  kustomize_release=$(curl -s https://api.github.com/repos/kubernetes-sigs/kustomize/releases | $JQ -r '.[].tag_name | select(contains("kustomize"))' \
    | sort -rV | head -n 1)
  kustomize_version=$(basename ${kustomize_release})
  echo "kustomize version is $kustomize_version"

  # kubeseal latest
  kubeseal_version=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases | $JQ -r '.[].tag_name | select(startswith("v"))' \
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
    --output normal --progress normal \
    -t ${image}:${tag} ${buildx_extra_args[@]} .
  docker buildx rm alpine-k8s

  # run test
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

[[ -f "$(dirname $0)/.env" ]] && echo loading .env && source "$(dirname $0)/.env"

if [[ "$(uname -s)" == "Darwin" ]]; then
  GREP=$(which ggrep) || brew install grep && GREP=$(which ggrep)
  JQ=$(which jq) || brew install jq
fi

if [[ "$(uname -s)" == "Linux" ]] && [ ! -x ./jq ]; then
  # jq 1.6
  curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o jq
  chmod +x jq
  JQ="$(pwd)/jq"
fi

# Construct docker hub path from env if unset
if [[ -z "$DOCKER_IMAGE_PATH" ]]; then
  CIRCLE_REPOSITORY_URL=${CIRCLE_REPOSITORY_URL-$(git remote get-url origin)}
  image="${CIRCLE_REPOSITORY_URL//.git}"
  image="${image/*:/}"
else
  image=$DOCKER_IMAGE_PATH
fi
echo "Docker repository is $image"

curl -s https://kubernetes.io/releases/ | (
  if [[ -x "$(which html2text)" ]]; then
    html2text -nobs
  else
    docker run -i --rm -v $(pwd):/app alpine/html2text -nobs
  fi
) |
   awk -F '[ :]' '/Latest Release:/ { print $3 }' |
  while read tag
do
  echo "Building ${image}/${tag}"
  status=$(curl -sL "https://hub.docker.com/v2/repositories/${image}/tags/${tag}")
  echo "$status"
  if [[ ( "${status}" =~ "not found" ) || ( ${REBUILD} == "true" ) ]]; then
     build
  fi
done
