#!/bin/bash

set -e
#set -x

: ${ENABLE_HOOK_ARGOCD_NAMESPACES_TO_RANCHER_PROJECTS:="false"}

# meant to be configured externally at launch time
: ${ARGOCD_NAMESPACE:=argocd}

: ${RANCHER_URI:="https://rancher.cattle-system"}

: ${ARGOCD_NAMESPACES_TO_RANCHER_PROJECTS_CLUSTER_NAME_EXCLUDE_REGEX:=""}
: ${ARGOCD_NAMESPACES_TO_RANCHER_PROJECTS_CLUSTER_NAME_INCLUDE_REGEX:=""}

: ${ARGOCD_NAMESPACES_TO_RANCHER_PROJECTS_PROJECT_NAME_EXCLUDE_REGEX:=""}
: ${ARGOCD_NAMESPACES_TO_RANCHER_PROJECTS_PROJECT_NAME_INCLUDE_REGEX:=""}

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
: ${K8S_EXTRA_ARGS:=""}

# https://github.com/flant/shell-operator/issues/726
if [[ $1 == "--config" ]]; then
  if [[ "${ENABLE_HOOK_ARGOCD_NAMESPACES_TO_RANCHER_PROJECTS}" == "true" ]]; then
    cat <<EOF
configVersion: v1
kubernetes:
- apiVersion: management.cattle.io/v3
  kind: Cluster
  executeHookOnEvent: [ "Added", "Modified", "Deleted" ]
- apiVersion: management.cattle.io/v3
  kind: Project
  executeHookOnEvent: [ "Added", "Modified", "Deleted" ]
- apiVersion: argoproj.io/v1alpha1
  kind: Application
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

if [[ -z "${RANCHER_URI}" ]]; then
  echo "RANCHER_URI must be set"
  exit 1
fi

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

# sanely handle 'remote' cluster CA
if [[ -n "${K8S_CA_DATA}" ]]; then
  echo "${K8S_CA_DATA}" >/tmp/rancher-ca-tls.crt
  K8S_EXTRA_ARGS+=" --certificate-authority=/tmp/rancher-ca-tls.crt "
fi

if [[ -z "${K8S_TOKEN}" ]]; then
  # gather up info for secret creation
  user=$(kubectl get users.management.cattle.io -o json -l 'authz.management.cattle.io/bootstrapping=admin-user' | jq -crM '.items[0]')
  userResourceName=$(echo "$user" | jq -crM '.metadata.name')
  token=$(kubectl get tokens.management.cattle.io -o json -l "authn.management.cattle.io/token-userId=${userResourceName},authn.management.cattle.io/kind=kubeconfig" | jq -crM '.items[0]')
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

RANCHER_CLUSTERS=$(kubectl get clusters.management.cattle.io -o json)
RANCHER_PROJECTS=$(kubectl get projects.management.cattle.io -A -o json)
ARGOCD_APPLICATIONS=$(kubectl -n "${ARGOCD_NAMESPACE}" get applications.argoproj.io -o json)

# iterate rancher clusters and associate namespaces to proper rancher project
echo $RANCHER_CLUSTERS | jq -crM '.items[]' | while read -r cluster; do

  cluster=$(echo "${cluster}" | jq -crM 'del(.metadata.labels."objectset.rio.cattle.io/hash")')
  clusterResourceName=$(echo "${cluster}" | jq -crM '.metadata.name')
  clusterDisplayName=$(echo "${cluster}" | jq -crM '.spec.displayName')
  echo "cluster ${clusterResourceName} display name: ${clusterDisplayName}"

  if [[ -z "${clusterResourceName}" ]]; then
    echo "empty cluster, moving on"
    continue
  fi

  # cluster exclude filtering
  if [[ -n "${ARGOCD_NAMESPACES_TO_RANCHER_PROJECTS_CLUSTER_NAME_EXCLUDE_REGEX}" ]]; then
    if [[ "${clusterDisplayName}" =~ ${ARGOCD_NAMESPACES_TO_RANCHER_PROJECTS_CLUSTER_NAME_EXCLUDE_REGEX} ]]; then
      echo "ignoring cluster ${clusterDisplayName} due to exclude filtering"
      continue
    fi
  fi

  # cluster include filtering
  if [[ -n "${ARGOCD_NAMESPACES_TO_RANCHER_PROJECTS_CLUSTER_NAME_INCLUDE_REGEX}" ]]; then
    if ! [[ "${clusterDisplayName}" =~ ${ARGOCD_NAMESPACES_TO_RANCHER_PROJECTS_CLUSTER_NAME_INCLUDE_REGEX} ]]; then
      echo "ignoring cluster ${clusterDisplayName} due to include filtering"
      continue
    fi
  fi

  # this is kube-ca
  caCert=$(echo "${cluster}" | jq -crM '.status.caCert')

  #
  NAMESPACES=$(kubectl --server="${RANCHER_URI}/k8s/clusters/${clusterResourceName}" --token="${K8S_TOKEN}" --insecure-skip-tls-verify="${K8S_INSECURE}" ${K8S_EXTRA_ARGS} get ns -o json)

  echo $NAMESPACES | jq -crM '.items[]' | while read -r namespace; do
    nsName=$(echo "${namespace}" | jq -crM '.metadata.name')

    # support explicit override
    projectName=$(echo "${namespace}" | jq -crM '.metadata.labels."rancher-to-argocd/projectName" | select (.!=null)')

    if [[ -n "${projectName}" ]]; then
      :
      echo "using project name ${projectName} from custom label"
    fi

    # lookup argocd project based on argocd application label
    if [[ -z "${projectName}" ]]; then
      argocdApplicationName=$(echo "${namespace}" | jq -crM '.metadata.labels."argocd.argoproj.io/instance" | select (.!=null)')

      if [[ -z "${argocdApplicationName}" ]]; then
        continue
      fi

      argocdApplication=$(echo $ARGOCD_APPLICATIONS | jq -crM --arg name "${argocdApplicationName}" '.items[] | select( .metadata.name == $name )')

      if [[ -n "${argocdApplication}" ]]; then
        :
        projectName=$(echo "${argocdApplication}" | jq -crM '.spec.project | select (.!=null)')

        if [[ -n "${projectName}" ]]; then
          :
          echo "using project name ${projectName} from argocd application label"
        fi
      fi
    fi

    # no project to link to
    if [[ -z "${projectName}" ]]; then
      echo "no project associated with namespace ${nsName}, skipping"
      continue
    fi

    # project exclude filtering
    if [[ -n "${ARGOCD_NAMESPACES_TO_RANCHER_PROJECTS_PROJECT_NAME_EXCLUDE_REGEX}" ]]; then
      if [[ "${projectName}" =~ ${ARGOCD_NAMESPACES_TO_RANCHER_PROJECTS_PROJECT_NAME_EXCLUDE_REGEX} ]]; then
        echo "ignoring project ${projectName} due to exclude filtering"
        continue
      fi
    fi

    # project include filtering
    if [[ -n "${ARGOCD_NAMESPACES_TO_RANCHER_PROJECTS_PROJECT_NAME_INCLUDE_REGEX}" ]]; then
      if ! [[ "${projectName}" =~ ${ARGOCD_NAMESPACES_TO_RANCHER_PROJECTS_PROJECT_NAME_INCLUDE_REGEX} ]]; then
        echo "ignoring project ${projectName} due to include filtering"
        continue
      fi
    fi

    rancherProject=$(echo $RANCHER_PROJECTS | jq -crM --arg namespace "${clusterResourceName}" --arg project "${projectName}" '.items[] | select( .metadata.namespace == $namespace and .spec.displayName == $project )')

    if [[ -z "${rancherProject}" ]]; then
      echo "no corresponding rancher project ${projectName}, skipping"
      continue
    fi

    if [[ -n "${rancherProject}" ]]; then
      rancherProjectId=$(echo $rancherProject | jq -crM '.metadata.name')
    fi

    if [[ -n "${projectName}" && -n "${rancherProjectId}" ]]; then
      currentRancherProjectId=$(echo "${namespace}" | jq -crM '.metadata.labels."field.cattle.io/projectId" | select (.!=null)')
      if [[ "${currentRancherProjectId}" != "${rancherProjectId}" ]]; then
        :
        echo "joining namespace ${nsName} to project ${projectName} (${rancherProjectId})"
        # set the label
        kubectl --server="${RANCHER_URI}/k8s/clusters/${clusterResourceName}" --token="${K8S_TOKEN}" --insecure-skip-tls-verify="${K8S_INSECURE}" ${K8S_EXTRA_ARGS} label --overwrite ns "${nsName}" "field.cattle.io/projectId=${rancherProjectId}"
        # set the annotation
        kubectl --server="${RANCHER_URI}/k8s/clusters/${clusterResourceName}" --token="${K8S_TOKEN}" --insecure-skip-tls-verify="${K8S_INSECURE}" ${K8S_EXTRA_ARGS} annotate --overwrite ns "${nsName}" "field.cattle.io/projectId=${clusterResourceName}:${rancherProjectId}"
      fi
    fi
  done
done
