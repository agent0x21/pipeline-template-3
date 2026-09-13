Design a reusable, production-grade CI/CD pipeline architecture with built-in semantic versioning, independent component versioning, prerelease management, artifact promotion, manual version-bump overrides, and release management.

The solution must work as a drop-in CI/CD framework for:

- New repositories
- Existing repositories with minimal or no restructuring
- Single-application repositories
- Monorepos
- Polyglot monorepos containing applications, libraries, services, infrastructure, or packages written in different languages and using different build systems
- Modern .NET applications
- Legacy .NET / .NET Framework applications that require Windows, MSBuild, Visual Studio Build Tools, or other Windows-specific tooling

The pipeline should make as few assumptions as possible about the repository's language, framework, package manager, CI provider, or build tooling, except for the explicit Windows and PowerShell requirements described below.

The end result should behave like a reusable CI/CD product rather than a pipeline written specifically for one repository.

## Core platform requirements

### 1. Windows-based runners

All CI/CD pipelines must be designed to execute on Windows-based runners.

This is a hard requirement because repositories may contain legacy .NET applications that cannot be reliably built on Linux runners.

The architecture must support workloads that may require:

- .NET Framework
- modern .NET
- `dotnet`
- MSBuild
- Visual Studio Build Tools
- NuGet
- Windows SDKs
- legacy `.sln` and `.csproj` formats
- SDK-style `.csproj` projects
- PowerShell
- Node.js
- Java
- Python
- Go
- Rust
- Docker tooling where supported by the Windows runner
- other tools installable or executable on Windows

Do not assume that all .NET projects can be built using:

`dotnet build`

Some applications may instead require commands such as:

`MSBuild.exe`

or Visual Studio Build Tools.

The pipeline architecture must allow the component-specific build adapter to choose the appropriate build mechanism.

The pipeline should also account for the fact that Windows runner images differ between CI providers.

Where runner prerequisites are required, define:

- what tooling must exist on the runner
- how tooling is discovered
- how missing prerequisites are handled
- how runner capabilities can be validated before builds begin

Prefer explicit capability checks over failures occurring deep within a build.

### 2. PowerShell scripting requirement

All custom CI/CD scripts must be written in PowerShell.

Do not introduce Bash, shell scripts, Python scripts, JavaScript scripts, or other scripting languages for pipeline orchestration unless there is an unavoidable technical requirement.

Reusable pipeline tooling should preferably be implemented as PowerShell modules or `.ps1` scripts.

For example:

```text
eng/
  ci/
    Get-ChangedComponents.ps1
    Get-ReleasePlan.ps1
    Get-NextVersion.ps1
    Invoke-ComponentBuild.ps1
    Invoke-ComponentTest.ps1
    New-ReleaseTag.ps1
    Publish-Component.ps1
    Promote-Artifact.ps1
```

Where shared functionality becomes substantial, consider a PowerShell module such as:

```text
eng/
  ci/
    ReleasePipeline/
      ReleasePipeline.psd1
      ReleasePipeline.psm1
```

Prefer PowerShell 7 (`pwsh`) for new orchestration logic where possible.

However, account for legacy applications or tooling that may require Windows PowerShell 5.1 (`powershell.exe`).

Clearly distinguish when:

- PowerShell 7 is preferred
- Windows PowerShell 5.1 is required
- a child build process requires Windows-specific tooling independent of the PowerShell version

Avoid relying on Unix-only commands such as:

```text
grep
sed
awk
bash
chmod
find
```

Use native PowerShell equivalents.

PowerShell scripts should:

- use terminating errors appropriately
- return non-zero exit codes on failure
- use structured objects internally rather than parsing human-readable strings
- support CI-friendly output
- avoid dependence on interactive prompts
- support verbose/debug logging
- support deterministic execution
- be independently testable where practical
- use consistent parameter validation
- avoid embedding CI-provider-specific environment-variable logic throughout the codebase

Prefer explicit parameters to provider-specific global state.

## Versioning requirements

### 3. Semantic versioning

Use Semantic Versioning:

`major.minor.patch`

Examples:

`1.0.0`
`2.4.7`

Support prerelease versions:

`major.minor.patch-beta.build`

and:

`major.minor.patch-rc.build`

Examples:

`2.4.0-beta.1`
`2.4.0-beta.2`
`2.4.0-rc.1`
`2.4.0-rc.2`
`2.4.0`

The pipeline must automatically calculate versions and must never intentionally create the same release version or Git tag twice.

Version calculation must be deterministic and safe when multiple pipeline executions occur close together.

Support:

- major releases
- minor releases
- patch releases
- beta prereleases
- release candidates
- stable releases
- repositories without previous release tags
- repositories with an existing release/tag history
- independently versioned components within a monorepo

Git tags should be the canonical release-version source unless there is a compelling architectural reason to use another source.

Do not require a language-specific file such as:

- `package.json`
- `pom.xml`
- `.csproj`
- `pyproject.toml`
- `Cargo.toml`

to be the authoritative version source.

### 4. Default version-bump policy

The automatic version-bump policy must be intentionally simple:

**All automatic version bumps should default to a minor version increment.**

For example:

Current version:

`2.4.7`

Default next base version:

`2.5.0`

The pipeline should not automatically infer patch or major bumps from Conventional Commits or source-code analysis unless explicitly configured to do so.

The default behavior should therefore be:

```text
2.4.7 → 2.5.0
3.1.4 → 3.2.0
7.9.2 → 7.10.0
```

For prereleases:

```text
2.4.7
↓
2.5.0-beta.1
↓
2.5.0-beta.2
↓
2.5.0-rc.1
↓
2.5.0
```

This default must apply independently to each releasable component.

For example:

```text
orders/v2.4.7 → orders/v2.5.0-beta.1
payments/v4.1.2 → payments/v4.2.0-beta.1
```

Only components selected for release should receive a new version.

### 5. Manual version-bump overrides

Users must be able to explicitly override the default minor bump when a different version increment is required.

Supported bump types should include at least:

- `major`
- `minor`
- `patch`

The default must remain:

`minor`

The preferred user experience is a simple workflow-run input, release parameter, or equivalent CI-provider-supported selection.

For example, a manually triggered workflow might expose:

```text
Version bump:
[ minor ▼ ]

Options:
- major
- minor
- patch
```

The framework should support the equivalent concept across CI providers.

For GitHub Actions, this could conceptually use `workflow_dispatch` inputs.

For Azure DevOps, it could use runtime parameters.

For Jenkins, it could use a choice parameter.

For another CI provider, use its equivalent manual-run input mechanism.

The core PowerShell release engine must not depend directly on one provider's implementation.

Instead, the CI provider should pass a normalized value such as:

```powershell
.\eng\ci\Get-ReleasePlan.ps1 -VersionBump minor
```

or:

```powershell
.\eng\ci\Get-ReleasePlan.ps1 -VersionBump major
```

The version-bump parameter should be validated against an allowed set.

For example:

```powershell
param(
    [ValidateSet('major', 'minor', 'patch')]
    [string] $VersionBump = 'minor'
)
```

This is illustrative; recommend the most appropriate PowerShell API.

### 6. Automatic versus manual release behavior

Normal branch-triggered CI/CD runs should use:

`minor`

unless an explicit override has been supplied through an approved mechanism.

Do not require users to provide a version bump on every normal pipeline run.

The automatic path should remain zero-touch.

Conceptually:

```text
Push to develop
→ changed component detected
→ no version override supplied
→ minor selected automatically
→ orders/v2.5.0-beta.1
```

A manually triggered release could instead specify:

```text
Version bump: patch
```

resulting in:

```text
orders/v2.4.8-beta.1
```

or:

```text
Version bump: major
```

resulting in:

```text
orders/v3.0.0-beta.1
```

depending on the release channel.

### 7. Per-component overrides in monorepos

For independently versioned monorepos, support simple per-component bump overrides when multiple components are being released in the same run.

For example:

```text
orders:
  bump: major

payments:
  bump: patch

customer-web:
  bump: minor
```

Do not require per-component selection for the common case.

The global default should remain:

`minor`

A reasonable precedence model would be:

1. Explicit per-component bump override
2. Explicit workflow-wide bump override
3. Default bump type: `minor`

For example:

```text
Default:
minor

Workflow override:
patch

Component override:
orders = major
```

would result in:

```text
orders       → major
payments     → patch
customer-web → patch
```

Explain and recommend a simple mechanism for specifying component-specific overrides.

Possible approaches include:

- workflow inputs
- a small JSON/YAML release-override file
- a release manifest
- a PowerShell parameter
- a combination of these

Prefer simplicity and auditability over sophisticated automatic inference.

### 8. Release override manifest

For complex monorepo releases, optionally support a small release-override manifest.

For example:

```yaml
defaultBump: minor

components:
  orders:
    bump: major

  payments:
    bump: patch
```

The pipeline could receive this file as an explicit release input or use a well-known repository location.

Do not require the manifest for normal operation.

The standard path should continue to work with no release manifest and should default to minor version bumps.

The architecture should define precedence clearly if both workflow inputs and a release manifest are supplied.

Avoid ambiguous behavior.

### 9. Explicit version selection

Optionally discuss whether an advanced manual release mode should allow an authorized user to specify the exact next version.

For example:

`3.7.0`

However, if supported, exact-version selection must:

- be explicitly manual
- validate Semantic Versioning
- reject versions lower than or equal to the current applicable release
- prevent duplicate tags
- respect component tag namespaces
- be auditable
- not replace the simpler major/minor/patch mechanism for normal usage

Recommend whether exact-version overrides should be included or excluded from the initial design.

### 10. Independent component versioning

Independent versioning must be a first-class feature and the recommended default for monorepos.

Each independently releasable component should maintain its own semantic version history.

Examples:

`service-a/v2.3.0`
`service-b/v5.1.2`
`web/v1.8.0`

Prereleases should follow the same namespace:

`service-a/v2.4.0-beta.1`
`service-a/v2.4.0-beta.2`
`service-a/v2.4.0-rc.1`
`service-a/v2.4.0`

A release of one component must not unnecessarily change the version of unrelated components.

The framework should still optionally support unified repository versioning, but independent versioning should be treated as the primary monorepo design.

### 11. Branch-based release channels

Versions and Git tags must be generated according to the branch receiving the commit.

Use the following default release channels:

- `main` → stable
- `qa` → `rc`
- `develop` → `beta`

The branch names and corresponding channels must be configurable.

Stable:

`major.minor.patch`

QA / release candidate:

`major.minor.patch-rc.build`

Beta:

`major.minor.patch-beta.build`

Examples:

```text
api/v3.2.0-beta.1
api/v3.2.0-beta.2
api/v3.2.0-rc.1
api/v3.2.0
```

### 12. Prerelease build-number strategy

Do not use the CI provider's globally increasing build/run number as the prerelease build number.

Instead, use a:

**per-component + per-base-version + per-prerelease-channel sequence**

derived from existing Git tags.

For example:

```text
service-a/v2.5.0-beta.1
service-a/v2.5.0-beta.2
service-a/v2.5.0-beta.3
```

The next beta is:

`service-a/v2.5.0-beta.4`

When the same base version enters QA:

`service-a/v2.5.0-rc.1`

The beta and RC counters are independent.

A valid progression is:

```text
service-a/v2.5.0-beta.1
service-a/v2.5.0-beta.2
service-a/v2.5.0-beta.3
service-a/v2.5.0-rc.1
service-a/v2.5.0-rc.2
service-a/v2.5.0
```

When a new base version begins, prerelease numbering resets:

`service-a/v2.6.0-beta.1`

The prerelease counter must not come from:

- Git commit count
- CI pipeline ID
- CI run number
- timestamp
- repository-wide build counter

Keep CI run identity separate:

```text
Semantic version:
2.5.0-rc.3

Prerelease sequence:
3

CI run:
18492

Commit:
a71bc42

Artifact digest:
sha256:...
```

### 13. Base-version calculation

For each changed component, determine the next base version from:

1. its latest stable component release
2. the selected bump type

Examples:

Current:

`service-a/v2.4.7`

Default minor bump:

`2.5.0`

Manual patch override:

`2.4.8`

Manual major override:

`3.0.0`

Therefore:

```text
Default develop release:
service-a/v2.5.0-beta.1

Patch override:
service-a/v2.4.8-beta.1

Major override:
service-a/v3.0.0-beta.1
```

Do not automatically infer a different bump type merely because a commit contains `fix:`, `feat:`, or `BREAKING CHANGE`.

Conventional Commits may still be used for:

- changelog generation
- component scoping
- release notes
- audit information

but the default bump policy remains explicitly minor unless the user selects another bump type.

### 14. Promotion semantics

Design the versioning model so software can naturally progress through:

`beta → rc → stable`

For example:

```text
service-a/v2.5.0-beta.1
service-a/v2.5.0-beta.2
service-a/v2.5.0-rc.1
service-a/v2.5.0-rc.2
service-a/v2.5.0
```

Prefer promotion of immutable artifacts rather than rebuilding source at each stage.

The same compiled artifact should ideally progress through beta, QA/RC, and production.

For container images, multiple semantic aliases may refer to the same digest.

For legacy .NET applications, use an equivalent immutable-artifact mechanism such as:

- ZIP archives
- NuGet packages
- Web Deploy packages
- MSI packages
- deployment bundles

Clearly distinguish:

- source version
- semantic version
- selected bump type
- prerelease channel
- prerelease sequence
- CI run identifier
- Git commit SHA
- artifact identifier
- artifact digest
- Git tag
- deployment environment

## Repository workflows

### 15. Single-application repositories

For a repository containing one deployable application, the framework should behave as though there is one independently versioned component.

The workflow should:

1. Validate the Windows runner.
2. Detect the triggering branch.
3. Detect whether a manual bump override was supplied.
4. Use `minor` when no override exists.
5. Determine the current stable version.
6. Calculate the next base version.
7. Determine the release channel.
8. Calculate the prerelease sequence if applicable.
9. Select the build adapter.
10. Build.
11. Test.
12. Package.
13. Record provenance.
14. Safely reserve/create the release.
15. Publish the artifact.
16. Promote or deploy according to policy.

### 16. Polyglot monorepo support

The same framework must work for repositories containing combinations of:

- Node.js / TypeScript
- Java / Kotlin
- modern .NET
- .NET Framework
- legacy Visual Studio solutions
- Python
- Go
- Rust
- Docker
- Terraform
- Helm
- frontend applications
- backend services
- shared libraries
- Windows services
- CLI tools
- infrastructure components

All repository-level CI/CD automation must remain PowerShell-based.

Language-specific tools may be invoked from PowerShell.

Examples:

```powershell
dotnet build .\src\Api\Api.csproj

& $MSBuildPath `
    ".\src\LegacyApplication\LegacyApplication.sln" `
    "/p:Configuration=Release"

pnpm install --frozen-lockfile
pnpm build

mvn package

python -m pytest

cargo build --release
```

### 17. Legacy .NET support

Legacy .NET support must be a first-class requirement.

Support applications that may require:

- .NET Framework 4.x
- older Visual Studio solution formats
- non-SDK-style `.csproj`
- `packages.config`
- NuGet restore
- MSBuild
- Visual Studio Build Tools
- Windows SDK components
- Web Deploy
- ASP.NET
- Windows Services
- Windows-only installers or packaging systems

Do not require these applications to be modernized before adopting the pipeline.

Do not hard-code the path to MSBuild.

Use a reliable discovery mechanism, such as Visual Studio installation tooling, and explain how it should work.

### 18. Change detection

For monorepos, detect which components changed.

Avoid rebuilding, versioning, publishing, or deploying unaffected components where practical.

Clearly distinguish:

**affected**

from:

**requires a release**

A dependent component may require rebuilding or testing without necessarily receiving a new semantic version.

Implement repository-independent change detection using PowerShell and Git.

### 19. Component dependency graph

Support an explicit or discoverable dependency graph.

For example:

```text
common-lib
   ├── orders-api
   └── payments-api

orders-api
   └── customer-web
```

Use it for:

- change propagation
- build ordering
- testing
- release decisions
- artifact dependencies
- release ordering

The selected version bump for one component must not automatically force the same bump type onto unrelated components.

## Configuration and extensibility

### 20. Drop-in adoption

Prefer a small repository-level configuration file.

For example:

```yaml
versioning:
  strategy: independent
  source: git-tags
  defaultBump: minor

runtime:
  operatingSystem: windows
  scripting: powershell

branches:
  main:
    channel: stable

  qa:
    channel: rc

  develop:
    channel: beta

components:
  api:
    path: services/api
    type: modern-dotnet
    tagPrefix: api/v

  legacy-web:
    path: applications/legacy-web
    type: legacy-dotnet-framework
    tagPrefix: legacy-web/v

  web:
    path: apps/web
    type: node
    tagPrefix: web/v

  worker:
    path: services/worker
    type: python
    tagPrefix: worker/v
```

The configuration should allow the default bump type to be changed if needed, but the recommended default is:

`minor`

### 21. Component configuration

Allow component-specific lifecycle configuration.

For example:

```yaml
components:
  orders-api:
    path: services/orders
    type: modern-dotnet

    build:
      command: dotnet build

    test:
      command: dotnet test

  legacy-portal:
    path: applications/legacy-portal
    type: legacy-dotnet-framework

    build:
      script: eng/ci/components/Build-LegacyPortal.ps1

    test:
      script: eng/ci/components/Test-LegacyPortal.ps1

  customer-web:
    path: apps/customer-web
    type: node

    build:
      command: pnpm build

    test:
      command: pnpm test
```

Any custom lifecycle scripts must be PowerShell.

### 22. PowerShell adapter architecture

Design reusable PowerShell adapters.

For example:

```text
eng/
  ci/
    adapters/
      DotNet.psm1
      LegacyDotNet.psm1
      Node.psm1
      Java.psm1
      Python.psm1
```

Conceptual operations may include:

```powershell
Restore-Component
Build-Component
Test-Component
Package-Component
Publish-Component
```

Versioning logic must remain separate from these build adapters.

## Git and release management

### 23. Git tag naming

Prefer:

`<component>/v<semver>`

Examples:

```text
orders/v1.4.0
orders/v1.5.0-beta.1
orders/v1.5.0-rc.1

payments/v3.7.2
payments/v3.8.0-beta.1
```

Tag parsing and version discovery must be unambiguous.

### 24. Pull requests

Pull-request builds should not normally create permanent release tags.

Use non-release traceability identities such as:

`orders:pr-482-a71bc42`

PR validation should not consume prerelease sequence numbers.

### 25. CI-platform portability

The framework should support Windows runners across providers such as:

- GitHub Actions
- Azure DevOps
- Jenkins
- GitLab CI where suitable Windows runners are available
- Bitbucket or other CI systems where suitable Windows execution is available

CI YAML should primarily handle:

- triggers
- Windows runner selection
- authentication
- caching
- artifact transfer
- approvals
- normalized inputs
- invoking PowerShell

Semantic version logic must live in reusable PowerShell, not provider-specific YAML.

### 26. Manual workflow inputs

Provide an implementation example showing how the chosen CI platform exposes a simple version-bump selector.

The desired interaction should be equivalent to:

```text
Run workflow

Version bump:
minor

Available options:
major
minor
patch
```

The default should be:

`minor`

The selected value should be passed into the PowerShell release engine.

Show how normal push-triggered executions behave when no manual input exists.

They should automatically use:

`minor`

### 27. Release CLI / PowerShell tooling

Prefer reusable PowerShell tooling.

Conceptual commands might include:

```powershell
Get-ReleaseChanges
Get-AffectedComponent
Get-CurrentVersion
Get-NextVersion
New-ReleasePlan
Invoke-ReleaseBuild
New-ReleaseTag
Publish-ReleaseArtifact
Invoke-ArtifactPromotion
```

`Get-NextVersion` or its equivalent must accept a bump type and default to minor.

For example:

```powershell
Get-NextVersion `
    -CurrentVersion '2.4.7' `
    -BumpType 'minor'
```

would produce:

`2.5.0`

### 28. Release planning

Produce a machine-readable release plan before building.

For example:

```yaml
defaultBump: minor

components:
  orders:
    changed: true
    currentVersion: 2.4.7
    bump: minor
    bumpSource: default
    nextBaseVersion: 2.5.0
    channel: beta
    prereleaseNumber: 3
    nextVersion: 2.5.0-beta.3

  payments:
    changed: true
    currentVersion: 4.1.2
    bump: patch
    bumpSource: manual-override
    nextBaseVersion: 4.1.3
    channel: beta
    prereleaseNumber: 1
    nextVersion: 4.1.3-beta.1
```

Include information indicating why each bump type was selected.

Possible values might include:

```text
default
workflow-override
component-override
release-manifest
exact-version-override
```

This makes release decisions auditable.

## Reliability and concurrency

### 29. Concurrency and race conditions

Prevent two executions from creating the same component version.

For example, two concurrent jobs must not both successfully claim:

`orders/v2.5.0-beta.4`

Consider:

- serialized release operations
- atomic Git tag pushes
- compare-and-set behavior
- retry after tag conflict
- component/channel-specific locking

Prefer approaches that do not require a centralized database.

Any implementation must be PowerShell-based.

### 30. Idempotency and reruns

A pipeline rerun must not create a new version merely because a job was retried.

If:

`orders/v2.5.0-rc.2`

has already been created, a failed deployment retry should continue deploying:

`orders/v2.5.0-rc.2`

It must not create:

`orders/v2.5.0-rc.3`

Clearly distinguish:

- new source release
- rerun
- rebuild
- publication retry
- deployment retry
- artifact promotion

### 31. Mapping releases to commits

Every semantic release must resolve to exactly one Git commit.

Multiple component tags may point to the same commit.

For example:

```text
orders/v2.5.0-beta.3
payments/v4.2.0-beta.1
```

may both point to:

`a71bc42`

### 32. Artifact provenance

Record:

- component
- semantic version
- selected bump type
- source of the bump decision
- Git commit
- Git tag
- CI run ID
- repository
- build timestamp
- artifact digest
- dependency versions where practical
- runner details where useful

The CI run identifier must remain separate from the semantic version.

### 33. Git history

Ensure the pipeline fetches enough Git history and tags to determine:

- current component version
- next version
- prerelease sequence
- previous component release
- changed files/components

Do not assume shallow checkout defaults are sufficient.

### 34. Security and permissions

Use least privilege.

Separate permissions for:

- checkout
- tag creation
- artifact publishing
- registry publishing
- release metadata
- deployment

Prefer OIDC or other short-lived identity mechanisms.

Do not expose secrets in PowerShell command-line arguments where they may appear in logs or process inspection.

### 35. Release failure semantics

Define behavior for:

- version calculated but build fails
- tests fail
- package creation fails
- tag conflict occurs
- tag succeeds but publishing fails
- artifact publishes but deployment fails
- promotion fails
- one monorepo component succeeds and another fails
- MSBuild cannot be found
- targeting packs are unavailable
- the selected version bump is invalid
- an exact version override conflicts with an existing tag

Explain when a new version is allocated and when the existing release must be reused.

## Migration and compatibility

### 36. Existing repositories

Support migration from repository-global tags such as:

```text
v1.2.0
v1.3.0
```

to independent tags such as:

```text
api/v1.4.0
web/v2.1.0
```

Allow explicit bootstrap versions.

For example:

```yaml
components:
  api:
    initialVersion: 1.4.0

  web:
    initialVersion: 2.1.0
```

Do not require Git history rewriting.

Existing batch or `.cmd` build tooling may be invoked by PowerShell where migration is impractical, but all newly created release and pipeline orchestration should use PowerShell.

### 37. Example version lifecycles

Show examples using the default minor-bump behavior.

For example:

Current:

```text
orders/v2.4.7
payments/v4.1.2
```

Only orders changes.

Default release:

```text
orders/v2.5.0-beta.1
```

Another orders build:

```text
orders/v2.5.0-beta.2
```

QA:

```text
orders/v2.5.0-rc.1
```

Production:

```text
orders/v2.5.0
```

Then show manual overrides.

Patch override:

```text
orders/v2.5.0
↓
orders/v2.5.1-beta.1
```

Major override:

```text
orders/v2.5.0
↓
orders/v3.0.0-beta.1
```

Also show a multi-component release where:

- orders uses the default `minor`
- payments receives a manual `patch`
- legacy-portal receives a manual `major`

### 38. PowerShell implementation examples

All custom implementation examples must use PowerShell.

Provide representative code or pseudocode for:

- configuration loading
- version-bump input validation
- defaulting an unspecified bump to minor
- resolving global and per-component bump overrides
- discovering Git tags
- parsing semantic versions
- determining current component versions
- incrementing major/minor/patch versions
- calculating prerelease sequence numbers
- detecting changed paths
- resolving affected components
- building a dependency graph
- constructing the release plan
- serializing the release plan as JSON
- MSBuild discovery
- modern .NET build invocation
- legacy .NET build invocation
- non-.NET build invocation
- Git tag creation
- atomic tag pushes
- conflict handling
- artifact hashing
- publishing
- promotion
- error handling

Use idiomatic PowerShell.

Prefer:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
```

or an equivalent robust error model.

### 39. PowerShell testing strategy

Recommend Pester tests for at least:

- semantic-version parsing
- default minor bump behavior
- patch overrides
- major overrides
- invalid bump rejection
- per-component override precedence
- workflow-level override precedence
- prerelease numbering
- branch-to-channel mapping
- Git tag parsing
- dependency traversal
- change detection
- release-plan construction
- concurrency retry behavior
- exact-version validation if that capability is implemented

### 40. Windows runner strategy

Compare:

- Microsoft-hosted Windows runners
- self-hosted Windows runners
- ephemeral Windows runners

Discuss when self-hosted or specialized runners may be needed for:

- older Visual Studio versions
- proprietary SDKs
- specific .NET Framework developer packs
- COM dependencies
- licensed software
- internal resources

Avoid relying on undocumented state on a single persistent Windows build machine.

## Required output

### 41. Output structure

Provide the proposed solution in the following structure:

1. Architecture overview
2. Core design principles
3. Windows runner architecture
4. PowerShell automation architecture
5. Legacy .NET compatibility strategy
6. Independent component versioning model
7. Default minor-bump strategy
8. Manual major/minor/patch override strategy
9. Per-component override strategy
10. Override precedence rules
11. Semantic-version calculation algorithm
12. Branch/channel model
13. Prerelease-number algorithm
14. Git tag naming convention
15. Release planning algorithm
16. Change-detection algorithm
17. Component dependency graph
18. Dependency-driven release behavior
19. Promotion model
20. Immutable artifact strategy
21. Single-application workflow
22. Polyglot monorepo workflow
23. Modern .NET workflow
24. Legacy .NET Framework workflow
25. Component/plugin architecture
26. PowerShell adapter architecture
27. Repository configuration schema
28. Release-override schema
29. Release-plan schema
30. CI-provider-neutral PowerShell pseudocode
31. PowerShell release-tool design
32. Manual workflow input example
33. Concurrency/race-condition solution
34. Idempotency and retry semantics
35. Git tagging strategy
36. Artifact provenance model
37. Security model
38. Pull-request behavior
39. Existing-repository migration strategy
40. Complete versioning examples
41. PowerShell implementation examples
42. PowerShell/Pester testing strategy
43. Failure scenarios and recovery
44. Edge cases
45. Recommended repository conventions
46. Tradeoffs and alternative approaches
47. Final recommended architecture

For every major design decision, explain:

- the recommended approach
- why it is recommended
- alternatives considered
- tradeoffs
- failure modes

Pay particular attention to:

- automatic version bumps always defaulting to minor
- major and patch bumps requiring an explicit override
- making bump overrides easy for users to select when manually running a workflow
- independent per-component versioning
- simple per-component bump overrides for monorepos
- clear override precedence
- auditable release decisions
- deterministic version calculation
- concurrency safety
- idempotency
- meaningful prerelease sequence numbers
- separating prerelease numbers from CI run IDs
- Windows runner compatibility
- legacy .NET Framework support
- reusable PowerShell automation
- avoiding CI-provider-specific release logic
- adopting the framework without requiring application modernization first
