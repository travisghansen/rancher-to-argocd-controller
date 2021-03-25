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
```

# permssions

```
- apiVersion: management.cattle.io/v3
  kind: Cluster

- apiVersion: management.cattle.io/v3
  kind: User

- apiVersion: management.cattle.io/v3
  kind: Token
```

# development

```
docker build -t foobar .
docker run -v ${KUBECONFIG}:/root/.kube/config --rm -ti --env-file .env                   foobar
docker run -v ${KUBECONFIG}:/root/.kube/config --rm -ti --env-file .env --entrypoint=bash foobar
```
