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

A parentless repository commit is treated as a bootstrap change: every configured component present in that commit receives its initial release version. For an existing repository, use the manual GitHub `release_all` input (or `New-ReleasePlan.ps1 -ReleaseAll`) only when an approved release must include every configured component regardless of source changes.

Channel version floors prevent branch regressions: QA releases must be above the latest stable version, and development releases must be above both the latest stable and QA/RC versions. The same validation applies to exact-version overrides; reruns of an existing tag remain idempotent.

Configuration loading rejects duplicate tag prefixes, invalid or escaping component paths, missing dependencies, dependency cycles, and unsupported branch channels. Component paths and optional legacy `build.solution` paths must exist relative to the configuration file. When a release tag for the planned component and channel already points to the planned commit, the plan is treated as a rerun and reuses that immutable version.

Tag pushes are atomic and retry transient push failures up to three times. If another runner creates the same tag first, the provisional local tag is removed; a matching remote commit is treated as an idempotent rerun, while a different remote commit fails safely and requires a newly reviewed plan.

The GitHub Actions adapter retains workflow artifacts for 30 days and publishes an idempotent GitHub release record for each tagged component. The provider-specific metadata script uses `GITHUB_TOKEN`; its behavior is intentionally kept outside the provider-neutral release module.

Promotion consumes an existing release artifact's `provenance.json`, validates its component/version/digest entries, and creates tags for the same commit without invoking a build. Only `beta -> rc` and `rc -> stable` are allowed. Use the **Promote Release** GitHub workflow with the source run ID; it downloads the retained source artifact and records the original artifact SHA-256 in `promotion-provenance.json`.

`pnpm test-ci-legacy` builds the included non-SDK-style .NET Framework 4.8 solution through `vswhere.exe` and MSBuild. Run it on a Windows machine with Visual Studio Build Tools and the [.NET Framework 4.8 Developer Pack](https://aka.ms/msbuild/developerpacks) installed; the command checks for the targeting pack before starting a build.

Packaging creates generic ZIP files and `artifacts/provenance.json`. The explicit `New-ReleaseTags.ps1` step is the only operation that mutates Git. It is idempotent when the requested tag already points to the planned commit and fails safely on a conflicting tag.

For legacy .NET components, set `type: legacy-dotnet-framework` and provide a PowerShell build command that discovers MSBuild (for example through `vswhere.exe`) and invokes it. Provider-specific workflows should pass normalized parameters to these scripts rather than embedding release logic.
