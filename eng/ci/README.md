# PowerShell release tooling

Read [the release standard](RELEASE-STANDARD.md) for the active lifecycle and [the roadmap](ROADMAP.md) before changing CI/CD.

The provider-neutral ReleasePipeline module supplies source validation, independent SemVer planning, affected-component detection, ZIP/container packaging, tag creation and RC-to-stable promotion planning. ReleasePlanning.ps1 contains the explicit RC model. ArtifactHandoff.ps1 validates v2 manifests, local ZIPs and sign-off identity.

The GitHub provider adapter uses durable draft/released GitHub assets, registry publication and GitHub reviewer history. Invoke-ReleaseBuild.ps1 builds or restores an RC; Invoke-ReleaseHandoff.ps1 supports PrepareQA, ApproveQA and PromotePROD. Its common handoff interface is release identity plus environment, independent of source branch names.

## Local planning and tests

```powershell
Install-Module powershell-yaml -RequiredVersion 0.4.12 -Scope CurrentUser
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser
pnpm release-plan
pnpm test-ci
```

Local planning defaults to RC and makes no tags. The GitHub adapter validates source eligibility before planning. ReleaseAll explicitly forces unchanged components. New-ReleasePlan accepts BaseRef for fixture/adoption scenarios; the default uses each component's reachable stable tag.

Configuration uses versioning, runtime, watchPaths, environments and components. Branch-channel mappings are rejected. Components define path, tagPrefix, build/test/package adapters, watched paths, optional dependencies and publishing adapters. All new orchestration is PowerShell; pnpm remains the JavaScript package manager.

Existing modern .NET, legacy MSBuild, ZIP, container and historical provenance adapters remain available. Legacy v1 helpers are not used by the new approval workflows. Invoke-EnvironmentDeployment is a legacy integration hook and requires a real configured deployment command; no current workflow invokes it.

## Future hosting integration

Consume the verified handoff's release ID, source SHA, artifact paths/checksums and image digests. Supply secrets and runtime configuration through DEV/QA/PROD. Add installation only after artifact verification, and write an actual deployment record only after the target confirms success. Do not bake environment values into or repackage the application artifacts.

The frontend accepts a separately hosted runtime-config.json; .NET configuration remains external. WPF distribution is manual ZIP delivery until an installer/distribution adapter is explicitly added.

See [provider mappings](PROVIDER-MAPPINGS.md) and [adoption templates](templates/README.md).
