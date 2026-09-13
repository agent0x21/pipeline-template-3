# ReleasePipeline

`ReleasePipeline` is the provider-neutral PowerShell core for this repository's CI/CD framework. It uses Git tags as the canonical version source and treats each configured component as independently releasable.

## Local usage

Install the YAML parser and the pinned Pester test dependency once, then plan and package:

```powershell
Install-Module powershell-yaml -Scope CurrentUser
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser
pwsh ./eng/ci/New-ReleasePlan.ps1 -Branch develop
pwsh ./eng/ci/Invoke-ReleasePackage.ps1 -PlanPath ./release-plan.json
```

Manual overrides are normalized JSON maps:

```powershell
./eng/ci/New-ReleasePlan.ps1 -VersionBump patch `
  -ComponentOverridesJson '{"api":"major"}' `
  -ExactVersionsJson '{}'
```

The precedence order is component override, workflow-wide override, then `versioning.defaultBump` (which defaults to `minor`). Tags use `<tagPrefix>/v<SemVer>`. Beta and RC sequence numbers are calculated from existing tags, independently for each component, base version, and channel.

Configuration loading rejects duplicate tag prefixes, invalid or escaping component paths, missing dependencies, dependency cycles, and unsupported branch channels. Component paths and optional legacy `build.solution` paths must exist relative to the configuration file. When a release tag for the planned component and channel already points to the planned commit, the plan is treated as a rerun and reuses that immutable version.

Tag pushes are atomic and retry transient push failures up to three times. If another runner creates the same tag first, the provisional local tag is removed; a matching remote commit is treated as an idempotent rerun, while a different remote commit fails safely and requires a newly reviewed plan.

The GitHub Actions adapter retains workflow artifacts for 30 days and publishes an idempotent GitHub release record for each tagged component. The provider-specific metadata script uses `GITHUB_TOKEN`; its behavior is intentionally kept outside the provider-neutral release module.

Packaging creates generic ZIP files and `artifacts/provenance.json`. The explicit `New-ReleaseTags.ps1` step is the only operation that mutates Git. It is idempotent when the requested tag already points to the planned commit and fails safely on a conflicting tag.

For legacy .NET components, set `type: legacy-dotnet-framework` and provide a PowerShell build command that discovers MSBuild (for example through `vswhere.exe`) and invokes it. Provider-specific workflows should pass normalized parameters to these scripts rather than embedding release logic.
