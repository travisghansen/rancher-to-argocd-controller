#!/bin/bash

set -e
#set -x

# meant to be configured externally at launch time
: ${ENVIRONMENT_ID:=""}
: ${REGION_ID:=""}
: ${SERVER_NAME_PREFIX:=${ENVIRONMENT_ID}-}
: ${SERVER_NAME_SUFFIX:=""}

: ${SECRET_NAME_PREFIX:="argocd-cluster-"}
: ${SECRET_NAME_SUFFIX:=""}
: ${ARGOCD_NAMESPACE:=argocd}

: ${RANCHER_URI:="https://rancher.cattle-system"}
# K8S_CA_DATA takes precedence over these
# dynamically pull the CA data from cluster secret
: ${RANCHER_CA_SECRET_NAME:=""}
: ${RANCHER_CA_SECRET_NS:=""}
: ${RANCHER_CA_SECRET_KEY:="tls.crt"}

# user-supplied K8S connection details
: ${K8S_TOKEN:=""}
# https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/resources/add-tls-secrets
# should be base64 cert if supplied
# kubectl -n cattle-system get secrets tls-rancher-internal-ca -o json | jq -crM '.data."tls.crt"'
# not sure what this CA is
# kubectl -n cattle-system get secrets tls-ca -o json | jq -crM '.data."root_ca.pem"'
: ${K8S_CA_DATA:=""}
: ${K8S_INSECURE:="false"}

if [[ $1 == "--config" ]]; then
  cat <<EOF
configVersion: v1
kubernetes:
- apiVersion: management.cattle.io/v3
  kind: Cluster
  executeHookOnEvent: [ "Added", "Modified", "Deleted" ]
schedule:
- name: "every 15 min"
  crontab: "*/15 * * * *"
  allowFailure: true
EOF
  exit 0
fi

if [[ -z "${RANCHER_URI}" ]]; then
  echo "RANCHER_URI must be set"
  exit 1
fi

if [[ -z "${ENVIRONMENT_ID}" ]]; then
  echo "ENVIRONMENT_ID must be set"
  exit 1
fi

#env

# fetch CA data from cluster
if [[ -n "${RANCHER_CA_SECRET_NAME}" && -z "${K8S_CA_DATA}" ]]; then
  [[ -n "${RANCHER_CA_SECRET_NS}" ]] && {
    NS_ARGS="-n ${RANCHER_CA_SECRET_NS}"
  }

  K8S_CA_DATA=$(kubectl ${NS_ARGS} get secrets ${RANCHER_CA_SECRET_NAME} -o json | jq -crM ".data.\"${RANCHER_CA_SECRET_KEY}\"")

  if [[ -z "${K8S_CA_DATA}" ]]; then
    echo "failed to retrieve K8S_CA_DATA using secret ${RANCHER_CA_SECRET_NS}/${RANCHER_CA_SECRET_NAME}"
    exit 1
  fi

  echo "properly fetched caData from secret"
fi

if [[ -z "${K8S_TOKEN}" ]]; then
  # gather up info for secret creation
  user=$(kubectl get users.management.cattle.io -o json -l 'authz.management.cattle.io/bootstrapping=admin-user' | jq -crM '.items[0]')
  userResourceName=$(echo "$user" | jq -crM '.metadata.name')
  token=$(kubectl get tokens.management.cattle.io -o json -l "authn.management.cattle.io/token-userId=${userResourceName}" | jq -crM '.items[0]')
  tokenResourceName=$(echo "$token" | jq -crM '.metadata.name')
  userToken=$(echo "$token" | jq -crM '.token')

  #userToken="null"
  #tokenResourceName="null"
  # sanity check the data
  if [[ "${userToken}" == "null" || "${tokenResourceName}" == "null" ]]; then
    echo "failed to properly retrive bearerToken from rancher crds"
    exit 1
  fi

  K8S_TOKEN="${tokenResourceName}:${userToken}"
  echo "properly fetched bearerToken from rancher crds"
fi

if [[ -z "${K8S_TOKEN}" ]]; then
  echo "empty bearerToken"
  exit 1
fi

# iterate rancher clusters and create corresponding argocd clusters
kubectl get clusters.management.cattle.io -o json | jq -crM '.items[]' | while read -r cluster; do
  # removing this label so rancher does not remove the secret immediately thinking it owns the secret
  cluster=$(echo "${cluster}" | jq -crM 'del(.metadata.labels."objectset.rio.cattle.io/hash")')
  clusterResourceName=$(echo "${cluster}" | jq -crM '.metadata.name')
  echo "handling cluster: ${clusterResourceName}"

  if [[ -z "${clusterResourceName}" ]]; then
    echo "empty cluster, moving on"
    continue
  fi

  displayName=$(echo "${cluster}" | jq -crM '.spec.displayName')
  echo "cluster ${clusterResourceName} display name: ${displayName}"
  # this is kube-ca
  caCert=$(echo "${cluster}" | jq -crM '.status.caCert')
  clusterLabels=$(echo "${cluster}" | yq eval '.metadata.labels' - -P | sed "s/^/    /g")
  SECRET_YAML=$(
    cat <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME_PREFIX}${clusterResourceName}${SECRET_NAME_SUFFIX}
  labels:
${clusterLabels}
    argocd.argoproj.io/secret-type: cluster
    clusterId: "${displayName}"
    environmentId: "${ENVIRONMENT_ID}"
    regionId: "${REGION_ID}"
    rancherImported: "true"
type: Opaque
stringData:
  name: "${SERVER_NAME_PREFIX}${displayName}${SERVER_NAME_SUFFIX}"
  server: "${RANCHER_URI}/k8s/clusters/${clusterResourceName}"
  config: |
    {
      "bearerToken": "${K8S_TOKEN}",
      "tlsClientConfig": {
        "insecure": ${K8S_INSECURE},
        "caData": "${K8S_CA_DATA}"
      }
    }

EOF
  )

  #echo "${SECRET_YAML}"
  #continue
  echo "${SECRET_YAML}" | kubectl -n "${ARGOCD_NAMESPACE}" apply -f -

done
