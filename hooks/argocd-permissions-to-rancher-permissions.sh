#!/bin/bash

set -e
#set -x

: ${ENABLE_HOOK_ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS:="false"}

# meant to be configured externally at launch time
: ${ARGOCD_NAMESPACE:=argocd}

: ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_CLUSTER_NAME_EXCLUDE_REGEX:=""}
: ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_CLUSTER_NAME_INCLUDE_REGEX:=""}

: ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_PROJECT_NAME_EXCLUDE_REGEX:=""}
: ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_PROJECT_NAME_INCLUDE_REGEX:=""}

: ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_IGNORE_DEFAULT_PROJECT:="true"}

: ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_ROLE_NAME_EXCLUDE_REGEX:=""}
: ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_ROLE_NAME_INCLUDE_REGEX:=""}

: ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_GROUP_NAME_EXCLUDE_REGEX:=""}
: ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_GROUP_NAME_INCLUDE_REGEX:=""}

# template for the Rancher groupPrincipalName value; use {group} as the placeholder for the ArgoCD group name
# example: 'activedirectory_group://CN={group},OU=Groups,DC=corp,DC=example,DC=com'
# when unset the group name is used as-is
: ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_GROUP_PRINCIPAL_TEMPLATE:=""}

# JSON object with two distinct sections matching the structure of dev/role-map.yaml:
#   roles:  maps ArgoCD role name  -> { roleTemplateName } for the Rancher role template to assign
#   groups: maps ArgoCD group name -> { ldapGroupDN }      for the full LDAP/AD principal name
# example:
#   '{
#     "groups": {
#       "dev-team":  {"ldapGroupDN": "CN=Dev Team,OU=Groups,DC=corp,DC=example,DC=com"},
#       "ops-team":  {"ldapGroupDN": "CN=Ops Team,OU=Groups,DC=corp,DC=example,DC=com"}
#     },
#     "roles": {
#       "deploy":    {"roleTemplateName": "adc-project-member"},
#       "admin":     {"roleTemplateName": "adc-project-owner"},
#       "read-only": {"roleTemplateName": "adc-read-only"}
#     }
#   }'
: ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_ROLE_MAP:="{}"}

# fallback Rancher roleTemplateName when a role is not found in ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_ROLE_MAP.roles
: ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_DEFAULT_ROLE:="project-member"}

# https://github.com/flant/shell-operator/issues/726
# https://github.com/flant/shell-operator/blob/main/docs/src/HOOKS.md
if [[ $1 == "--config" ]]; then
  if [[ "${ENABLE_HOOK_ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS}" == "true" ]]; then
    cat <<EOF
configVersion: v1
settings:
  executionMinInterval: 60s
  executionBurst: 1
kubernetes:
- apiVersion: management.cattle.io/v3
  kind: Cluster
  executeHookOnEvent: [ "Added" ]
  allowFailure: true
  queue: "${0}"
  group: "${0}"
- apiVersion: management.cattle.io/v3
  kind: Project
  executeHookOnEvent: [ "Added", "Modified", "Deleted" ]
  allowFailure: true
  queue: "${0}"
  group: "${0}"
- apiVersion: management.cattle.io/v3
  kind: ProjectRoleTemplateBinding
  executeHookOnEvent: [ "Deleted" ]
  allowFailure: true
  queue: "${0}"
  group: "${0}"
- apiVersion: argoproj.io/v1alpha1
  kind: AppProject
  executeHookOnEvent: [ "Added", "Modified", "Deleted" ]
  allowFailure: true
  queue: "${0}"
  group: "${0}"
schedule:
- name: "every 15 min"
  crontab: "*/15 * * * *"
  allowFailure: true
  queue: "${0}"
  group: "${0}"
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
RANCHER_PROJECTS=$(kubectl get projects.management.cattle.io -A -o json)

echo $ARGOCD_PROJECTS | jq -crM '.items[]' | while read -r appProject; do
  appProjectName=$(echo "${appProject}" | jq -crM '.metadata.name')
  echo "handling appproject: ${appProjectName}"

  # project exclude filtering
  if [[ -n "${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_PROJECT_NAME_EXCLUDE_REGEX}" ]]; then
    if [[ "${appProjectName}" =~ ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_PROJECT_NAME_EXCLUDE_REGEX} ]]; then
      echo "ignoring project ${appProjectName} due to exclude filtering"
      continue
    fi
  fi

  # project include filtering
  if [[ -n "${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_PROJECT_NAME_INCLUDE_REGEX}" ]]; then
    if ! [[ "${appProjectName}" =~ ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_PROJECT_NAME_INCLUDE_REGEX} ]]; then
      echo "ignoring project ${appProjectName} due to include filtering"
      continue
    fi
  fi

  if [[ "${appProjectName}" == "default" && "${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_IGNORE_DEFAULT_PROJECT}" == "true" ]]; then
    echo "ignoring project ${appProjectName} due to ignore default"
    continue
  fi

  echo $RANCHER_CLUSTERS | jq -crM '.items[]' | while read -r cluster; do
    cluster=$(echo "${cluster}" | jq -crM 'del(.metadata.labels."objectset.rio.cattle.io/hash")')
    clusterResourceName=$(echo "${cluster}" | jq -crM '.metadata.name')

    if [[ -z "${clusterResourceName}" ]]; then
      echo "empty cluster, moving on"
      continue
    fi

    clusterDisplayName=$(echo "${cluster}" | jq -crM '.spec.displayName')
    echo "handling cluster: ${clusterResourceName} (${clusterDisplayName})"

    # cluster exclude filtering
    if [[ -n "${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_CLUSTER_NAME_EXCLUDE_REGEX}" ]]; then
      if [[ "${clusterDisplayName}" =~ ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_CLUSTER_NAME_EXCLUDE_REGEX} ]]; then
        echo "ignoring cluster ${clusterDisplayName} due to exclude filtering"
        continue
      fi
    fi

    # cluster include filtering
    if [[ -n "${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_CLUSTER_NAME_INCLUDE_REGEX}" ]]; then
      if ! [[ "${clusterDisplayName}" =~ ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_CLUSTER_NAME_INCLUDE_REGEX} ]]; then
        echo "ignoring cluster ${clusterDisplayName} due to include filtering"
        continue
      fi
    fi

    rancherProject=$(echo $RANCHER_PROJECTS | jq -crM --arg namespace "${clusterResourceName}" --arg project "${appProjectName}" 'first(.items[] | select( .metadata.namespace == $namespace and .spec.displayName == $project )) // empty')
    if [[ -z "${rancherProject}" ]]; then
      echo "no matching rancher project for ${appProjectName} in cluster ${clusterResourceName}, skipping"
      continue
    fi

    rancherProjectId=$(echo $rancherProject | jq -crM '.metadata.name // empty')
    rancherProjectBackingNamespace=$(echo $rancherProject | jq -crM '.status.backingNamespace // empty')

    if [[ -z "${rancherProjectId}" || -z "${rancherProjectBackingNamespace}" ]]; then
      echo "missing project id or backing namespace for ${appProjectName} in cluster ${clusterResourceName}, skipping"
      continue
    fi

    echo "syncing bindings for project ${appProjectName} (${rancherProjectId}) in cluster ${clusterResourceName}"

    existingPRTBs=$(kubectl get projectroletemplatebindings.management.cattle.io -n "${rancherProjectBackingNamespace}" -o json 2>/dev/null || echo '{"items":[]}')

    # temp file accumulates desired groupPrincipalName<TAB>roleTemplateName pairs so the GC
    # pass below can diff against it; tab separator avoids collision with colons in principal names
    tmpDesired=$(mktemp)

    echo $appProject | jq -crM '.spec.roles[]? | {name: .name, groups: (.groups // [])}' | while read -r role; do
      roleName=$(echo "${role}" | jq -crM '.name')

      # role exclude filtering
      if [[ -n "${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_ROLE_NAME_EXCLUDE_REGEX}" ]]; then
        if [[ "${roleName}" =~ ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_ROLE_NAME_EXCLUDE_REGEX} ]]; then
          echo "ignoring role ${roleName} due to exclude filtering"
          continue
        fi
      fi

      # role include filtering
      if [[ -n "${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_ROLE_NAME_INCLUDE_REGEX}" ]]; then
        if ! [[ "${roleName}" =~ ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_ROLE_NAME_INCLUDE_REGEX} ]]; then
          echo "ignoring role ${roleName} due to include filtering"
          continue
        fi
      fi

      rancherRoleName=$(echo "${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_ROLE_MAP}" | jq -crM --arg role "${roleName}" '.roles[$role].roleTemplateName // empty' 2>/dev/null)
      if [[ -z "${rancherRoleName}" ]]; then
        rancherRoleName="${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_DEFAULT_ROLE}"
      fi

      if [[ -z "${rancherRoleName}" ]]; then
        echo "no role mapping for argocd role ${roleName}, skipping"
        continue
      fi

      echo "${role}" | jq -crM '.groups[]?' | while read -r group; do
        # group exclude filtering
        if [[ -n "${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_GROUP_NAME_EXCLUDE_REGEX}" ]]; then
          if [[ "${group}" =~ ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_GROUP_NAME_EXCLUDE_REGEX} ]]; then
            echo "ignoring group ${group} due to exclude filtering"
            continue
          fi
        fi

        # group include filtering
        if [[ -n "${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_GROUP_NAME_INCLUDE_REGEX}" ]]; then
          if ! [[ "${group}" =~ ${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_GROUP_NAME_INCLUDE_REGEX} ]]; then
            echo "ignoring group ${group} due to include filtering"
            continue
          fi
        fi

        # resolve groupPrincipalName: groups section of ROLE_MAP takes precedence over GROUP_PRINCIPAL_TEMPLATE
        ldapGroupDN=$(echo "${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_ROLE_MAP}" | jq -crM --arg group "${group}" '.groups[$group].ldapGroupDN // empty' 2>/dev/null)
        if [[ -n "${ldapGroupDN}" ]]; then
          groupPrincipalName="${ldapGroupDN}"
        elif [[ -n "${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_GROUP_PRINCIPAL_TEMPLATE}" ]]; then
          groupPrincipalName="${ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS_GROUP_PRINCIPAL_TEMPLATE//\{group\}/${group}}"
        else
          groupPrincipalName="${group}"
        fi

        # record this pair as desired before the duplicate check so existing PRTBs are preserved
        printf '%s\t%s\n' "${groupPrincipalName}" "${rancherRoleName}" >>"${tmpDesired}"

        existingPRTB=$(echo $existingPRTBs | jq -crM --arg group "${groupPrincipalName}" --arg role "${rancherRoleName}" '.items[] | select( .groupPrincipalName == $group and .roleTemplateName == $role )')

        if [[ -n "${existingPRTB}" ]]; then
          echo "PRTB already exists for group ${groupPrincipalName} with role ${rancherRoleName} in project ${appProjectName}"
          continue
        fi

        echo "creating PRTB for group ${groupPrincipalName} with role ${rancherRoleName} in project ${appProjectName} (${rancherProjectId})"

        # NOTE: if the roleTemplateName is not present the rancher admission hook will reject the request
        # NOTE: if the ldap group does not exist creation will work fine, but show an error in the UI about unable to find group
        PRTB_YAML=$(
          cat <<EOF
---
apiVersion: management.cattle.io/v3
kind: ProjectRoleTemplateBinding
metadata:
  generateName: prtb-
  namespace: ${rancherProjectBackingNamespace}
  labels:
    argocdImported: "true"
groupPrincipalName: ${groupPrincipalName}
projectName: ${clusterResourceName}:${rancherProjectId}
roleTemplateName: ${rancherRoleName}
EOF
        )

        #echo "${PRTB_YAML}"
        # apply does not work with generateName
        echo "${PRTB_YAML}" | kubectl create -f - || echo "failed to create PRTB"
      done
    done

    # garbage collect managed PRTBs that are no longer in the desired state
    echo $existingPRTBs | jq -crM '.items[] | select(.metadata.labels.argocdImported == "true")' | while read -r prtb; do
      prtbName=$(echo $prtb | jq -crM '.metadata.name // empty')
      prtbGroup=$(echo $prtb | jq -crM '.groupPrincipalName // empty')
      prtbRole=$(echo $prtb | jq -crM '.roleTemplateName // empty')

      if [[ -z "${prtbName}" || -z "${prtbGroup}" || -z "${prtbRole}" ]]; then
        continue
      fi

      if ! grep -qxF "$(printf '%s\t%s' "${prtbGroup}" "${prtbRole}")" "${tmpDesired}" 2>/dev/null; then
        echo "deleting stale PRTB ${prtbName} (group: ${prtbGroup}, role: ${prtbRole}) from project ${appProjectName} in cluster ${clusterResourceName}"
        kubectl delete projectroletemplatebindings.management.cattle.io -n "${rancherProjectBackingNamespace}" "${prtbName}"
      fi
    done

    rm -f "${tmpDesired}"
  done
done
