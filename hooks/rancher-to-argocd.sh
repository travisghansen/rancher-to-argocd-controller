#!/bin/bash

set -e
#set -x

# meant to be configured externally at launch time
: ${ENVIRONMENT_ID:=""}
: ${SERVER_NAME_PREFIX:=${ENVIRONMENT_ID}-}
: ${SERVER_NAME_SUFFIX:=""}
: ${RANCHER_URI:=""}
: ${SECRET_NAME_PREFIX:="argocd-cluster-"}
: ${SECRET_NAME_SUFFIX:=""}
: ${ARGOCD_NAMESPACE:=argocd}

if [[ $1 == "--config" ]] ; then
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

if [[ -z "${RANCHER_URI}" ]];then
  echo "RANCHER_URI must be set"
  exit 1
fi

if [[ -z "${ENVIRONMENT_ID}" ]];then
  echo "ENVIRONMENT_ID must be set"
  exit 1
fi

#env

# gather up info for secret creation
user=$(kubectl get users.management.cattle.io -o json -l 'authz.management.cattle.io/bootstrapping=admin-user' | jq -crM '.items[0]')
userResourceName=$(echo "$user" | jq -crM '.metadata.name')
token=$(kubectl get tokens.management.cattle.io -o json -l "authn.management.cattle.io/token-userId=${userResourceName}" | jq -crM '.items[0]')
tokenResourceName=$(echo "$token" | jq -crM '.metadata.name')
userToken=$(echo "$token" | jq -crM '.token')

# iterate rancher clusters and create corresponding argocd clusters
for cluster in $(kubectl get clusters.management.cattle.io -o json | jq -crM '.items[]'); do
  echo "handling cluster: ${cluster}"
  clusterResourceName=$(echo "${cluster}" | jq -crM '.metadata.name')

  if [[ -z "${clusterResourceName}" ]];then
    continue;
  fi

  displayName=$(echo "${cluster}" | jq -crM '.spec.displayName')
  caCert=$(echo "${cluster}" | jq -crM '.status.caCert')
  clusterLabels=$(echo "${cluster}" | yq eval '.metadata.labels' - -P | sed "s/^/    /g")

  cat <<EOF | kubectl -n "${ARGOCD_NAMESPACE}" apply -f -
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
    rancherImported: "true"
type: Opaque
stringData:
  name: "${SERVER_NAME_PREFIX}${displayName}${SERVER_NAME_SUFFIX}"
  server: "${RANCHER_URI}/k8s/clusters/${clusterResourceName}"
  config: |
    {
      "bearerToken": "${tokenResourceName}:${userToken}",
      "tlsClientConfig": {
        "insecure": false,
        "caData": ""
      }
    }

EOF

done
