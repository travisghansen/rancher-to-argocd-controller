# v0.5.0

- add cleanup logic to remove orphaned ArgoCD cluster secrets when Fleet/Rancher clusters are deleted
- add support for deriving ArgoCD clusters from fleet clusters instead (set FLEET_MODE="true")
- add support for omitting cluster name prefix (set SERVER_NAME_PREFIX="NONE")

# v0.4.3

Released 2025-06-24

- performance improvements and throttling/grouping/queing

# v0.4.2

Released 2025-06-23

- properly support discovery of CA data for use with `remote` cluster operations

# v0.4.1

Released 2025-06-23

- properly support discovery of CA data for use with `remote` cluster operations

# v0.4.0

Released 2025-06-23

- support syncing argocd projects to rancher projects
- support assigning namespaces to rancher projects
- minor fixes and version bumps

# v0.3.2

Released 2023-06-15

- support setting ca data
- support dynamically fetching ca data from k8s secret
- support setting insecure flag
- more robust failure detection to prevent writing secrets with `null` values
