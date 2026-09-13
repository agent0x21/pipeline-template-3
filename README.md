# pipeline-template-2
Build, Version, Package &amp; Deploy

See [application versioning and artifact builds](scripts/versioning/README.md) for the PowerShell commands, release policy, dependency detection, and CI workflow.

## Release pipeline tooling

The reusable Windows/PowerShell release framework is in `eng/ci/ReleasePipeline`. It reads `.releasepipeline.yml`, uses component-scoped Git tags, defaults to minor bumps, and emits JSON release plans and generic ZIP artifacts with provenance.

```powershell
pnpm release-plan
pnpm release-package
pnpm test-ci
```

The GitHub Actions adapter is `.github/workflows/release.yml`. Tag creation is a separate explicit step; use `pnpm release-tags` only from an approved release run. Install `powershell-yaml` for local YAML parsing:

```powershell
Install-Module powershell-yaml -Scope CurrentUser
```
