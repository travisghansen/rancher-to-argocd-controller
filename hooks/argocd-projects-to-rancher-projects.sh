#!/bin/bash

set -e
#set -x

: ${ENABLE_HOOK_ARGOCD_PROJECTS_TO_RANCHER_PROJECTS:="false"}

# meant to be configured externally at launch time
: ${ARGOCD_NAMESPACE:=argocd}

: ${ARGOCD_PROJECTS_TO_RANCHER_PROJECTS_CLUSTER_NAME_EXCLUDE_REGEX:=""}
: ${ARGOCD_PROJECTS_TO_RANCHER_PROJECTS_CLUSTER_NAME_INCLUDE_REGEX:=""}

: ${ARGOCD_PROJECTS_TO_RANCHER_PROJECTS_PROJECT_NAME_EXCLUDE_REGEX:=""}
: ${ARGOCD_PROJECTS_TO_RANCHER_PROJECTS_PROJECT_NAME_INCLUDE_REGEX:=""}

: ${ARGOCD_PROJECTS_TO_RANCHER_PROJECTS_IGNORE_DEFAULT_PROJECT:="true"}

# https://github.com/flant/shell-operator/issues/726
if [[ $1 == "--config" ]]; then
  if [[ "${ENABLE_HOOK_ARGOCD_PROJECTS_TO_RANCHER_PROJECTS}" == "true" ]]; then
    cat <<EOF
configVersion: v1
kubernetes:
- apiVersion: management.cattle.io/v3
  kind: Cluster
  executeHookOnEvent: [ "Added", "Modified", "Deleted" ]
- apiVersion: argoproj.io/v1alpha1
  kind: AppProject
  executeHookOnEvent: [ "Added", "Modified", "Deleted" ]
schedule:
- name: "every 15 min"
  crontab: "*/15 * * * *"
  allowFailure: true
EOF
  else
    cat <<EOF
configVersion: v1
settings:
  executionMinInterval: 1s
  executionBurst: 1
EOF
  fi

  exit 0
fi

ARGOCD_PROJECTS=$(kubectl -n "${ARGOCD_NAMESPACE}" get appprojects.argoproj.io -o json)
RANCHER_CLUSTERS=$(kubectl get clusters.management.cattle.io -o json)

# iterate rancher clusters and create corresponding argocd clusters
echo $RANCHER_CLUSTERS | jq -crM '.items[]' | while read -r cluster; do
  # removing this label so rancher does not remove the secret immediately thinking it owns the secret
  cluster=$(echo "${cluster}" | jq -crM 'del(.metadata.labels."objectset.rio.cattle.io/hash")')
  clusterResourceName=$(echo "${cluster}" | jq -crM '.metadata.name')
  echo "handling cluster: ${clusterResourceName}"

  if [[ -z "${clusterResourceName}" ]]; then
    echo "empty cluster, moving on"
    continue
  fi

  clusterDisplayName=$(echo "${cluster}" | jq -crM '.spec.displayName')
  echo "cluster ${clusterResourceName} display name: ${clusterDisplayName}"

  # cluster exclude filtering
  if [[ -n "${ARGOCD_PROJECTS_TO_RANCHER_PROJECTS_CLUSTER_NAME_EXCLUDE_REGEX}" ]]; then
    if [[ "${clusterDisplayName}" =~ ${ARGOCD_PROJECTS_TO_RANCHER_PROJECTS_CLUSTER_NAME_EXCLUDE_REGEX} ]]; then
      echo "ignoring cluster ${clusterDisplayName} due to exclude filtering"
      continue
    fi
  fi

  # cluster include filtering
  if [[ -n "${ARGOCD_PROJECTS_TO_RANCHER_PROJECTS_CLUSTER_NAME_INCLUDE_REGEX}" ]]; then
    if ! [[ "${clusterDisplayName}" =~ ${ARGOCD_PROJECTS_TO_RANCHER_PROJECTS_CLUSTER_NAME_INCLUDE_REGEX} ]]; then
      echo "ignoring cluster ${clusterDisplayName} due to include filtering"
      continue
    fi
  fi

  echo $ARGOCD_PROJECTS | jq -crM '.items[]' | while read -r appProject; do
    appProjectName=$(echo "${appProject}" | jq -crM '.metadata.name')
    projectDescription=$(echo "${appProject}" | jq -crM '.spec.description | select (.!=null)')

    # project exclude filtering
    if [[ -n "${ARGOCD_PROJECTS_TO_RANCHER_PROJECTS_PROJECT_NAME_EXCLUDE_REGEX}" ]]; then
      if [[ "${appProjectName}" =~ ${ARGOCD_PROJECTS_TO_RANCHER_PROJECTS_PROJECT_NAME_EXCLUDE_REGEX} ]]; then
        echo "ignoring project ${appProjectName} due to exclude filtering"
        continue
      fi
    fi

    # project include filtering
    if [[ -n "${ARGOCD_PROJECTS_TO_RANCHER_PROJECTS_PROJECT_NAME_INCLUDE_REGEX}" ]]; then
      if ! [[ "${appProjectName}" =~ ${ARGOCD_PROJECTS_TO_RANCHER_PROJECTS_PROJECT_NAME_INCLUDE_REGEX} ]]; then
        echo "ignoring project ${appProjectName} due to include filtering"
        continue
      fi
    fi

    if [[ "${appProjectName}" == "default" && "${ARGOCD_PROJECTS_TO_RANCHER_PROJECTS_IGNORE_DEFAULT_PROJECT}" == "true" ]]; then
      echo "ignoring project ${appProjectName} due to ignore default"
      continue
    fi

    echo "ensuring ${appProjectName} in ${clusterDisplayName}"

    PROJECT_YAML=$(
      cat <<EOF
---
apiVersion: management.cattle.io/v3
kind: Project
metadata:
  name: ${appProjectName}
  namespace: ${clusterResourceName}
  labels:
    argocdImported: "true"
spec:
  clusterName: ${clusterResourceName}
  description: ${projectDescription}
  displayName: ${appProjectName}
  containerDefaultResourceLimit: {}
  namespaceDefaultResourceQuota:
    limit: {}
  resourceQuota:
    limit: {}
    usedLimit: {}
EOF
    )

    #echo "${PROJECT_YAML}"
    echo "${PROJECT_YAML}" | kubectl apply -f -
  done
done

# TODO: remove any projects that are no longer in argocd but exist in rancher (ie: us the `argocdImported: "true"` label to determine what is managed)
