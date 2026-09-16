# Provider mappings

The lifecycle is provider-neutral: CI, manual DEV artifact creation, manual RC creation, QA attestation, then independently approved stable publication. Installation remains manual.

| Meaning | PowerShell contract | GitHub | Azure DevOps / Jenkins equivalent |
| --- | --- | --- | --- |
| Selected source | Resolve-ReleaseSource; full SHA | source_ref dispatch input | Explicit source parameter resolved once |
| Release intent | RC planning / stable promotion | Separate workflows | Separate stages/jobs |
| Version selection | VersionBump, ComponentOverrides, ExactVersions | Dispatch choices/JSON | Runtime parameters |
| Source baseline | Reachable component stable tags | Full history checkout | Full history checkout |
| Release set | v2 manifest and immutable artifact storage | release/run-id + GitHub Releases | Durable artifact store keyed by unique release ID |
| QA evidence | Manifest checksum + actual reviewers | QA environment and review-history API | Approval record naming the exact manifest hash |
| Production gate | Independent approval | PROD environment | Protected approval stage |
| Environment configuration | Runtime config and secrets | DEV / QA / PROD | Environment-scoped variable groups/credentials |

The GitHub provider scripts are intentionally GitHub-specific. Another provider must implement the store and reviewer-evidence adapter, not pretend GitHub environment variables are portable.

All orchestration executes on Windows with PowerShell 7; legacy tools can be invoked through their configured adapters. Retain full Git history, pnpm 12.3.4, immutable artifact checks and no-build promotion. Branches must never select an environment or semantic channel.
