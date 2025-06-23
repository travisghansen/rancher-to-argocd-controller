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
