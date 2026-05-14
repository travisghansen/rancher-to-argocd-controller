# intro

A simple controller to automatically create an argocd cluster for every cluster in a rancher installation.

# env

```
# is added as the `environmentId` label to the cluster secret
: ${ENVIRONMENT_ID:=""}
: ${SERVER_NAME_PREFIX:=${ENVIRONMENT_ID}-}
: ${SERVER_NAME_SUFFIX:=""}
# should be the URI to your rancher install
# ie: https://rancher.domain.com
: ${RANCHER_URI:=""}
: ${SECRET_NAME_PREFIX:="argocd-cluster-"}
: ${SECRET_NAME_SUFFIX:=""}
: ${ARGOCD_NAMESPACE:=argocd}

# enable the hook
: ${ENABLE_HOOK_RANCHER_CLUSTERS_TO_ARGOCD_CLUSTERS:="false"}

# enable the hook
: ${ENABLE_HOOK_ARGOCD_NAMESPACES_TO_RANCHER_PROJECTS:="false"}

# enable the hook
: ${ENABLE_HOOK_ARGOCD_PROJECTS_TO_RANCHER_PROJECTS:="false"}

# enable the hook
: ${ENABLE_HOOK_ARGOCD_PERMISSIONS_TO_RANCHER_PERMISSIONS:="false"}
```

# development

```
CLUSTER_NAME_INCLUDE_REGEX="workload-01" PROJECT_NAME_EXCLUDE_REGEX="default|system" ./hooks/argocd-projects-to-rancher-projects.sh

```

# permssions

```
# rancher-clusters-to-argocd-clusters.sh
- apiVersion: management.cattle.io/v3
  kind: Cluster
- apiVersion: management.cattle.io/v3
  kind: User
- apiVersion: management.cattle.io/v3
  kind: Token

# argocd-projects-to-rancher-projects.sh
- apiVersion: management.cattle.io/v3
  kind: Cluster
- apiVersion: management.cattle.io/v3
  kind: Project
- apiVersion: argoproj.io/v1alpha1
  kind: AppProject
```

# development

```
docker build -t foobar .
docker run -v ${KUBECONFIG}:/root/.kube/config --rm -ti --env-file .env                   foobar
docker run -v ${KUBECONFIG}:/root/.kube/config --rm -ti --env-file .env --entrypoint=bash foobar
```
