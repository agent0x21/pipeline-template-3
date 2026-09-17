# Repository Discovery Engine
## Functional Requirements Specification

**Status:** Draft  
**Purpose:** Functional specification for implementation planning  
**Primary consumers:** Engineering team, architecture review, implementation agent  
**Scope:** Repository discovery, classification, build/package inference, dependency analysis, change-impact analysis, and release-manifest scaffolding

**Repository integration date:** 2026-09-18  
**Implementation status:** Planned; adding this specification does not implement a scanner or change `.releasepipeline.yml`.

This companion to the [release pipeline functional requirements](FUNCTIONAL-REQUIREMENTS.md) preserves the supplied discovery specification and its requirement identifiers. [Section 60](#60-repository-integration-and-configuration-generation) adds first-file generation requirements and reconciles the draft's open schema questions with current repository code. Those repository-specific clarifications take precedence over provisional examples and open questions below. The complete product requirements entry point is [main-prompt.md](../../prompt/main-prompt.md).

---

# 1. Purpose

The Repository Discovery Engine analyzes a source-code repository and identifies independently buildable, testable, packageable, deployable, and publishable components.

Its purpose is to answer:

- What components exist in this repository?
- What technologies and frameworks do those components use?
- How can each component be built?
- How can each component be packaged?
- Which components produce deployable applications?
- Which components produce npm or NuGet packages?
- How do components depend on one another?
- Which components are affected by a Git change?
- Which conclusions are explicit and which have been inferred?
- Which newly discovered components should be proposed for addition to `.releasepipeline.yml`?

The engine is a **discovery and scaffolding system**, not a deployment orchestrator.

It must produce evidence-backed conclusions that a human or downstream system can inspect.

The existing `.releasepipeline.yml` remains the human-owned declaration of release intent. Discovery may propose additions but must not silently replace or reinterpret human-authored release configuration. The current repository already uses explicit component definitions for Node, modern .NET, Windows .NET, build commands, package locations, container publication, dependencies, and component-specific watch paths.

---

# 2. Goals

The discovery engine must support the following primary goals.

## 2.1 Repository understanding

The engine must automatically identify relevant projects and packages throughout a monorepo without requiring the caller to enumerate them manually.

## 2.2 Technology classification

The engine must classify discovered projects with more precision than the release pipeline necessarily requires.

For example:

```text
Discovery classification:
  ecosystem: javascript
  framework: vite-react
  applicationKind: spa

Release manifest projection:
  type: node
```

and:

```text
Discovery classification:
  ecosystem: dotnet
  framework: aspnet-core
  applicationKind: web-api

Release manifest projection:
  type: modern-dotnet
```

This separation allows discovery to remain rich while keeping `.releasepipeline.yml` intentionally concise.

## 2.3 Build and packaging inference

The engine must determine how each component can be built and what artifacts it can produce.

## 2.4 Publishable package detection

The engine must identify npm and NuGet packages intended or potentially intended for publication.

## 2.5 Dependency modeling

The engine must construct a repository-wide dependency graph.

## 2.6 Change-impact analysis

The engine must determine which components are directly and transitively affected by source changes.

## 2.7 Safe scaffolding

The engine must be able to propose missing `.releasepipeline.yml` component entries while preserving all existing human-authored configuration.

---

# 3. Non-Goals

The discovery engine is not responsible for:

- executing builds;
- executing tests;
- publishing artifacts;
- deploying applications;
- authenticating to package or container registries;
- selecting deployment environments;
- determining approval policy;
- choosing a CI/CD provider;
- generating GitHub Actions workflows;
- generating Azure DevOps pipelines;
- generating Jenkins pipelines;
- generating GitLab CI pipelines;
- deciding which external registry an artifact should be pushed to;
- changing existing human-authored release configuration;
- inferring credentials;
- inferring organizational security policy.

These responsibilities belong to separate execution, release-policy, or provider-adapter layers.

---

# 4. Architectural Principles

## FR-4.1 — Provider neutrality

The discovery engine must remain independent of any particular CI/CD provider.

It must not contain provider-specific concepts such as:

- runners;
- agents;
- jobs;
- stages;
- GitHub Actions expressions;
- Azure DevOps variables;
- Jenkins pipeline syntax;
- GitLab job definitions.

The repository model and release manifest form the interface between discovery and provider-specific execution.

The repository's existing design already separates release semantics from provider concerns, and the discovery system must preserve that boundary.

## FR-4.2 — Evidence-based conclusions

Every significant inferred value must be traceable to repository evidence.

Examples include:

- `package.json`;
- `pnpm-workspace.yaml`;
- `.csproj`;
- `.fsproj`;
- `.sln`;
- `.slnx`;
- `Directory.Build.props`;
- project SDK declarations;
- package references;
- project references;
- Dockerfiles;
- Docker Compose configuration;
- MSBuild properties;
- deployment configuration;
- package metadata;
- build scripts;
- framework-specific configuration files.

The engine must not silently guess.

## FR-4.3 — Explicit configuration outranks inference

The precedence order must be:

```text
Human-authored release configuration
        ↓
Explicit project configuration
        ↓
Strong framework convention
        ↓
Weak heuristic
```

A lower-precedence inference must never overwrite a higher-precedence explicit value.

## FR-4.4 — Discovery and release intent are distinct

Discovery describes what the repository appears capable of producing.

`.releasepipeline.yml` describes what the organization intends to release.

Those concepts overlap but are not equivalent.

For example, discovery may conclude that an ASP.NET project supports both:

```text
dotnet publish
container image
```

while `.releasepipeline.yml` may explicitly configure only the container release path.

## FR-4.5 — Best-effort discovery

Failure to classify one component must not prevent discovery of unrelated components.

Ambiguous components must remain visible.

## FR-4.6 — No unsafe defaults

Fields that could cause an artifact to be published to an incorrect external destination must never be guessed.

Examples include:

```text
container image destination
npm registry
NuGet feed
credentials
OIDC configuration
deployment environment
```

---

# 5. Existing Release Manifest Boundary

The current `.releasepipeline.yml` contains the following top-level areas:

```yaml
versioning:
runtime:
watchPaths:
environments:
components:
```



## FR-5.1 — Discovery-owned concerns

Discovery should primarily concern itself with:

```text
components
```

and may produce recommendations relating to:

```text
watchPaths
```

## FR-5.2 — Non-discovery concerns

Discovery must not infer or modify:

```text
versioning
runtime
environments
```

unless a future specification explicitly expands its responsibilities.

## FR-5.3 — Current component model

The existing manifest demonstrates support for component fields including:

```text
path
watchPaths
type
tagPrefix
build.command
test.command
package.path
publishing
dependencies
```



Discovery should project its richer internal model into this smaller release model rather than forcing every discovery attribute into `.releasepipeline.yml`.

---

# 6. Repository Root Discovery

## FR-6.1 — Starting location

The engine must accept a path located anywhere within a repository.

## FR-6.2 — Repository root identification

The engine must determine the repository root using repository characteristics.

Relevant signals may include:

```text
.git
.releasepipeline.yml
pnpm-workspace.yaml
solution files
repository-level build configuration
repository-level package configuration
```

No single JavaScript or .NET file should be required to establish repository identity.

The requirement is to identify the repository and services from their defining characteristics rather than requiring explicit enumeration.

## FR-6.3 — Root ambiguity

If multiple plausible repository boundaries exist, discovery must report the ambiguity rather than silently selecting an arbitrary nested workspace.

---

# 7. Repository Traversal

## FR-7.1 — Recursive discovery

Starting at the repository root, the scanner must recursively identify candidate projects.

## FR-7.2 — Generated directory exclusion

The scanner must avoid recursively processing directories that represent generated output or dependency caches.

At minimum:

```text
.git
node_modules
bin
obj
```

should normally be excluded.

## FR-7.3 — Configurable exclusions

The scanner architecture must allow additional exclusion patterns.

## FR-7.4 — Nested components

One detected component directory must not automatically prevent discovery of nested components.

For example:

```text
apps/web
apps/web/packages/widget
```

may legitimately contain separate packages.

Technology-specific workspace semantics should determine component boundaries where possible.

---

# 8. JavaScript and TypeScript Discovery

## FR-8.1 — Project identification

`package.json` is the primary project marker for JavaScript and TypeScript projects.

## FR-8.2 — Generic JavaScript/TypeScript support

Projects must not be classified as React merely because React exists elsewhere in the repository.

If no more specific framework can be identified, the engine should classify the project as generic JavaScript or TypeScript.

## FR-8.3 — Package metadata extraction

Relevant package metadata should include, where present:

```text
name
version
private
type
scripts
dependencies
devDependencies
peerDependencies
optionalDependencies
exports
main
module
types
files
publishConfig
workspaces
engines
packageManager
```

---

# 9. React Discovery

## FR-9.1 — React identification

React must primarily be identified through package metadata and framework-specific evidence.

Signals may include:

```text
react
react-dom
framework dependencies
build tooling
framework configuration
package scripts
```

## FR-9.2 — React classification

Where sufficient evidence exists, the engine should distinguish:

```text
Next.js
Remix
React Router framework applications
Vite React
Create React App
React library
Storybook-only project
Generic React
```

This classification requirement is based on the intended discovery behavior already established for the system.

## FR-9.3 — Storybook handling

A project containing Storybook must not automatically be classified as a deployable React application.

If Storybook is the project's only meaningful application surface, it may be classified as:

```text
storybook-only
```

## FR-9.4 — React library handling

A React library must be distinguishable from a React application.

Relevant signals may include:

```text
package exports
library-mode bundling
peer dependency on React
absence of application entry points
publishable package metadata
```

---

# 10. JavaScript Workspace Discovery

## FR-10.1 — pnpm support

The engine must support pnpm workspaces.

`pnpm-workspace.yaml` must be recognized as a workspace-definition source.

## FR-10.2 — Workspace membership

Workspace membership must supplement normal recursive discovery.

It must not be required for a package to be discovered.

## FR-10.3 — Other workspace systems

The architecture should permit support for:

```text
npm workspaces
Yarn workspaces
Nx
Turborepo
Rush
```

without coupling the core discovery model to one workspace implementation.

Initial implementation support beyond pnpm must be declared explicitly rather than assumed.

---

# 11. Generic Node Application Discovery

The engine must support non-React Node applications as distinct project types.

Candidate classifications may include:

```text
Node service
Node worker
CLI application
library
generic Node application
```

Framework-specific classification may include technologies such as:

```text
Express
Fastify
NestJS
```

where sufficient evidence exists.

Unsupported or unknown Node frameworks must fall back to a generic Node classification rather than being ignored.

---

# 12. .NET Project Discovery

## FR-12.1 — Project markers

`.csproj` and `.fsproj` files are the primary units of .NET project discovery.

## FR-12.2 — Solution files

Solution membership is contextual evidence, not the primary source of project identity.

A project outside a solution must still be discoverable.

## FR-12.3 — Project metadata

Classification should inspect relevant information including:

```text
Project SDK
TargetFramework
TargetFrameworks
OutputType
UseWPF
UseWindowsForms
UseMaui
IsTestProject
IsPackable
GeneratePackageOnBuild
FrameworkReference
PackageReference
ProjectReference
PublishProfile
container-related MSBuild properties
```

---

# 13. .NET Project Classification

The engine should distinguish, where evidence supports it:

```text
ASP.NET Core application
ASP.NET Core API
Worker Service
Console application
Azure Functions
Class library
Test project
Blazor application
MAUI application
Generic .NET project
```

Classification is primarily based on project metadata, SDK/package references, and target framework.

---

# 14. Legacy .NET Framework Discovery

## FR-14.1 — Non-SDK projects

The engine must recognize legacy .NET Framework projects using older MSBuild project formats.

## FR-14.2 — No modern SDK assumption

The absence of:

```text
Microsoft.NET.Sdk
```

must not cause a project to be discarded.

## FR-14.3 — Windows requirements

Where a project clearly requires Windows to build, discovery must represent that requirement.

## FR-14.4 — Release type mapping

Discovery must distinguish its internal classification from the release-pipeline `type`.

The current release manifest demonstrates:

```text
node
modern-dotnet
modern-dotnet-windows
```

as currently used values.

The discovery engine must not invent a new `.releasepipeline.yml` type unless that type is supported by the release manifest schema.

For example, a legacy .NET Framework project may internally be classified as:

```text
ecosystem: dotnet
runtimeFamily: net-framework
requiresWindows: true
```

If no corresponding release-manifest `type` exists, the scaffolding process must report that a type mapping requires human/schema input rather than fabricate one.

---

# 15. Artifact Discovery

## FR-15.1 — Supported artifact categories

The discovery engine must recognize the potential production of:

```text
container image
.NET publish output
static frontend assets
server-side Node bundle
ZIP deployment package
npm package
NuGet package
```



## FR-15.2 — Multiple artifacts

A component may produce multiple artifact forms.

For example:

```text
ASP.NET API
  ├─ dotnet publish directory
  ├─ ZIP archive
  └─ container image
```

The internal discovery model must therefore represent artifacts as a collection.

## FR-15.3 — Primary release artifact

Discovery must not assume that every technically possible artifact is actually intended for release.

Selection of the authoritative release artifact remains release configuration.

---

# 16. Packaging Evidence

Each packaging conclusion must record whether it is:

```text
explicit
inferred
```

## FR-16.1 — Explicit packaging

Examples include:

```text
Dockerfile
explicit build script
MSBuild packaging property
package publishing metadata
release configuration
deployment configuration
```

## FR-16.2 — Inferred packaging

Examples include:

```text
Vite convention → static dist output
ASP.NET convention → dotnet publish
packable class library → possible NuGet package
library package.json → possible npm package
```

## FR-16.3 — Evidence retention

The internal report must retain the source evidence used for the conclusion.

---

# 17. Docker and Container Discovery

## FR-17.1 — Dockerfile detection

Discovery must identify:

```text
project-local Dockerfiles
repository-level Dockerfiles
shared Dockerfiles
custom-named Dockerfiles
multi-stage Dockerfiles
```

## FR-17.2 — Dockerfile association

A Dockerfile must be associated with one or more components where evidence supports the association.

Possible evidence includes:

```text
COPY paths
build commands
project file references
package.json references
working directories
entry points
Docker Compose build configuration
```

## FR-17.3 — Shared Dockerfiles

A root-level or shared Dockerfile must not automatically be associated with every project.

## FR-17.4 — Docker Compose

Docker Compose files should be inspected for:

```text
service names
build contexts
Dockerfile paths
target stages
dependency relationships
```

## FR-17.5 — .NET SDK container publishing

The engine must detect .NET container publication that does not use a traditional Dockerfile when configured through MSBuild or publish settings.

## FR-17.6 — Multiple packaging strategies

A Dockerfile does not automatically suppress discovery of:

```text
dotnet publish
static assets
ZIP output
other package forms
```

Container support may be one packaging option among several.

---

# 18. npm Package Discovery

## FR-18.1 — Publication intent

The engine must identify JavaScript packages that appear intended to be published to an npm-compatible registry.

## FR-18.2 — Strong publication signals

Signals may include:

```text
private != true
name
version
publishConfig
exports
files
main/module/types
package build scripts
workspace usage
```

No single weak signal should necessarily be sufficient on its own.

## FR-18.3 — Private packages

A package explicitly containing:

```json
{
  "private": true
}
```

must not be classified as externally publishable.

It may still be:

```text
buildable
testable
an internal dependency
```

## FR-18.4 — Internal packages

An internal workspace package may require building even when it is not publishable.

Buildability and publishability must therefore be represented separately.

## FR-18.5 — npm registry

Discovery must not infer the target npm registry.

---

# 19. NuGet Package Discovery

## FR-19.1 — Explicit package signals

Strong evidence of NuGet publication includes:

```xml
<IsPackable>true</IsPackable>
```

and may also include:

```text
GeneratePackageOnBuild
PackageId
PackageVersion
Authors
Description
repository packaging conventions
```

## FR-19.2 — Explicit exclusion

A project containing:

```xml
<IsPackable>false</IsPackable>
```

must not be classified as publishable.

This explicit exclusion outranks inference.

## FR-19.3 — Potentially publishable class libraries

A class library for which normal SDK conventions allow packing may be classified as:

```text
potentially publishable
```

when no explicit package intent is present.

Such a conclusion must receive lower confidence than explicitly configured packaging.

## FR-19.4 — NuGet destination

Discovery must not infer the target NuGet feed.

---

# 20. Build Command Discovery

The engine must determine appropriate candidate build commands but must not execute them.

## FR-20.1 — Explicit command preference

Where an explicit project command exists, it should normally take precedence.

For example:

```json
{
  "scripts": {
    "build": "vite build"
  }
}
```

supports a workspace-aware command such as:

```text
pnpm --filter ./apps/web build
```

The existing release manifest already uses this form.

## FR-20.2 — .NET build commands

Depending on project/artifact type, candidate commands may include:

```text
dotnet build
dotnet publish
dotnet pack
```

The current manifest uses explicit `dotnet publish` commands for both API and desktop components.

## FR-20.3 — Container commands

Candidate container commands may include:

```text
docker build
dotnet publish / container targets
```

## FR-20.4 — Command origin

Every generated candidate command must indicate whether it was:

```text
explicit
derived
convention-default
```

---

# 21. Test Discovery

## FR-21.1 — Testability is separate from buildability

A component may be:

```text
buildable but not directly testable
testable but not publishable
publishable with external test projects
```

## FR-21.2 — JavaScript test commands

Discovery may propose a test command from explicitly defined scripts such as:

```text
test
lint
typecheck
check
```

but must preserve the actual script semantics.

For example, the existing `web` component uses its `lint` script as the configured release-pipeline test command.

Discovery must not assume that `lint` universally means `test`.

## FR-21.3 — .NET test projects

Projects identified as test projects should be associated with production components when a reliable relationship can be established through:

```text
ProjectReference
solution membership
repository conventions
explicit configuration
```

## FR-21.4 — Synthesized test commands

A command such as:

```text
dotnet test <project>
```

may be proposed when a test project has been confidently identified.

If the relationship between a test project and a production component is ambiguous, the relationship must be reported as unresolved.

---

# 22. Package Output Discovery

## FR-22.1 — Output path detection

The engine should determine expected artifact paths when evidence permits.

Examples include:

```text
Vite outDir
Next.js output
dotnet publish output
NuGet package output
configured dist directories
```

## FR-22.2 — Release output convention

If repository conventions define a release output directory such as:

```text
.release-output/<component>
```

the engine may propose that convention only when the convention can be established from existing repository configuration.

The current manifest uses `.release-output/api` and `.release-output/desktop` for .NET outputs.

## FR-22.3 — Unknown outputs

If output location cannot be determined safely, discovery must report the artifact without inventing a path.

---

# 23. Dependency Graph

## FR-23.1 — Graph model

The discovery engine must construct a directed component dependency graph.

For:

```text
A depends on B
```

the graph should represent:

```text
A → B
```

## FR-23.2 — JavaScript dependencies

The engine must inspect:

```text
dependencies
devDependencies
peerDependencies
optionalDependencies
workspace protocol references
workspace package resolution
```

Internal package names must be mapped to discovered components where possible.

## FR-23.3 — .NET dependencies

The engine must inspect:

```text
ProjectReference
internal PackageReference relationships
```

## FR-23.4 — Internal NuGet relationship

When a `PackageReference` matches a package produced by another discovered repository project, the engine may infer an internal dependency if the match is reliable.

That edge must be marked as inferred unless directly represented through project references or explicit configuration.

## FR-23.5 — Cross-ecosystem dependencies

Cross-ecosystem relationships may be represented where reliable evidence exists.

For example:

```text
frontend build consumes generated API client
service image copies frontend output
build script invokes another project
```

Weak proximity-based guesses must not create dependency edges.

## FR-23.6 — Edge origin

Each graph edge must indicate:

```text
explicit
inferred
```

## FR-23.7 — Cycles

Dependency cycles must be detected and reported.

The engine must not silently remove edges merely to produce an acyclic graph.

The graph is intended to support build order and transitive impact analysis.

---

# 24. `dependencies` Versus `watchPaths`

The internal discovery model must distinguish semantic dependencies from filesystem impact rules.

## FR-24.1 — Dependencies

A dependency represents a semantic component relationship.

Example:

```text
web depends on shared-ui
```

## FR-24.2 — Watch paths

A watch path represents a filesystem location whose change should affect a component.

Example:

```text
eng/build
Directory.Build.props
packages/generated
```

## FR-24.3 — Relationship

A component dependency may imply a watch relationship, but the two concepts are not equivalent.

## FR-24.4 — Projection to `.releasepipeline.yml`

The current manifest contains both `watchPaths` and `dependencies`, demonstrating that they are intended as separate concepts.

Discovery should preserve that distinction.

## FR-24.5 — Pending schema semantics

The precise runtime semantics of `.releasepipeline.yml.dependencies` should be formally documented before automatic projection is considered authoritative.

Until then:

- the discovery graph remains canonical inside the discovery report;
- dependencies may be proposed to the release manifest;
- existing human-authored dependency values must never be altered.

---

# 25. Git Change Impact Analysis

The engine must support both full discovery and change-oriented analysis.

## FR-25.1 — Full scan mode

A full scan analyzes the entire repository.

## FR-25.2 — Changed-file mode

The engine must support receiving a set of changed files.

## FR-25.3 — Git revision mode

The architecture should support deriving changed files from Git revisions, for example:

```text
base SHA
head SHA
```

## FR-25.4 — Direct impact

A component is directly affected when:

```text
a file inside the component changes
```

or:

```text
one of its watch paths changes
```

or:

```text
configuration known to influence it changes
```

## FR-25.5 — Transitive impact

If:

```text
App → Library A → Library B
```

and Library B changes, then:

```text
Library B = directly affected
Library A = transitively affected
App       = transitively affected
```

## FR-25.6 — Impact categories

The model should allow impact to be classified by operation where possible:

```text
build
test
package
publish
deploy
```

A change may affect some operations without necessarily affecting all operations.

---

# 26. Repository-Wide Impact

The engine must recognize files that potentially affect multiple components.

Examples include:

```text
pnpm-lock.yaml
pnpm-workspace.yaml
Directory.Build.props
Directory.Packages.props
global.json
shared build scripts
release configuration
```

The current release manifest already defines several repository-wide watch paths including `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `package.json`, `.releasepipeline.yml`, and `eng/ci`.

Discovery may recommend additional repository-level impact rules but must not silently replace the existing human-authored list.

---

# 27. Internal Discovery Model

The discovery engine must maintain an internal machine-readable model that is richer than `.releasepipeline.yml`.

JSON should be the canonical representation.

An illustrative component model is:

```json
{
  "id": "apps/api",
  "path": "apps/api",
  "ecosystem": "dotnet",
  "classification": {
    "framework": "aspnet-core",
    "applicationKind": "web-api",
    "targetFrameworks": ["netX.Y"],
    "requiresWindows": false
  },
  "build": {
    "candidates": []
  },
  "tests": [],
  "artifacts": [],
  "dependencies": [],
  "watchPaths": [],
  "releaseProjection": {},
  "evidence": [],
  "confidence": {},
  "issues": []
}
```

The precise schema must be versioned.

---

# 28. Stable Component Identity

## FR-28.1 — Stable IDs

Component identifiers must not depend on scanner traversal order.

## FR-28.2 — Preferred source

Where possible, identity should be derived from stable repository characteristics such as:

```text
repository-relative path
package name
project path
release component key
```

## FR-28.3 — Existing release mapping

When a discovered component matches an existing `.releasepipeline.yml` component, the existing component key should be retained as the release identity.

---

# 29. Evidence Model

Each inferred property should retain relevant evidence.

Example:

```json
{
  "file": "apps/web/package.json",
  "signal": "dependencies.react",
  "value": "^19.0.0",
  "supports": "classification.framework=react"
}
```

Another example:

```json
{
  "file": "apps/api/Dockerfile",
  "signal": "COPY apps/api",
  "supports": "artifact.container"
}
```

Evidence should be specific enough that a human reviewer can understand why discovery reached its conclusion without manually reverse-engineering the repository.

---

# 30. Confidence Model

Confidence must be attached to individual inferred properties rather than represented only once at component level.

Example:

```json
{
  "framework": {
    "value": "vite-react",
    "confidence": 0.99,
    "source": "inferred"
  },
  "artifact": {
    "value": "static-assets",
    "confidence": 0.82,
    "source": "inferred"
  }
}
```

A component may therefore be confidently identified while still having uncertain packaging.

The engine should support a numeric confidence score such as:

```text
0.0–1.0
```

A human-friendly category may additionally be derived:

```text
high
medium
low
```

but the numeric value should remain canonical if confidence scoring is implemented.

---

# 31. Ambiguity Model

Ambiguous findings must be preserved.

Example:

```json
{
  "component": "apps/example",
  "field": "primaryPackaging",
  "selected": "container",
  "alternatives": [
    "static-assets"
  ],
  "confidence": 0.54,
  "evidence": []
}
```

Low-confidence findings must not disappear from output. This follows the established requirement that discovery should make a best-effort determination, retain evidence, and avoid both silent guesses and unnecessary hard failures.

---

# 32. Discovery Report

A discovery run must be able to emit a standalone report.

The report should contain:

```text
repository information
discovered components
component classifications
build candidates
test candidates
artifacts
publication candidates
dependency graph
watch relationships
confidence
evidence
ambiguities
unresolved findings
change-impact results when applicable
release-manifest projection
```

This report is diagnostic and explanatory.

It is not itself the authoritative release configuration.

---

# 33. Release Manifest Projection

The engine must contain a projection layer responsible for mapping the rich discovery model onto the narrower `.releasepipeline.yml` model.

Conceptually:

```text
Discovery model
      │
      ▼
Projection
      │
      ▼
Proposed .releasepipeline.yml component
```

## FR-33.1 — Lossy projection is allowed

The projection may intentionally discard discovery detail.

For example:

```text
vite-react
nextjs
generic-node
```

may all project to:

```yaml
type: node
```

if that is the release schema's intended abstraction.

## FR-33.2 — Unsupported mappings

If the release schema cannot represent a discovered component correctly, projection must produce an unresolved mapping rather than inventing a value.

---

# 34. Existing Manifest Protection

`.releasepipeline.yml` remains human-owned.

## FR-34.1 — No overwrite

Discovery must never automatically overwrite an existing component field.

## FR-34.2 — Existing component matching

When a component is already present:

```text
discovery may compare
discovery may warn
discovery may suggest
discovery may not replace
```

## FR-34.3 — Conflicts

Example:

```text
Discovery says:
  type = modern-dotnet

Manifest says:
  type = modern-dotnet-windows
```

The manifest value remains authoritative.

The discrepancy may be reported.

## FR-34.4 — Human override mechanism

The existing `.releasepipeline.yml` itself is the override mechanism.

A separate `discovery.yml` file should not be required.

This reflects the earlier requirement to maintain one human-owned manifest rather than introducing competing configuration layers.

---

# 35. Discovery Operating Modes

The command surface should conceptually support three levels of side effect.

## FR-35.1 — Discovery mode

Example:

```text
discover
```

Behavior:

```text
scan repository
produce discovery report
produce proposed projection
do not modify repository files
```

This should be the default.

## FR-35.2 — Scaffold mode

Example:

```text
discover --scaffold
```

Behavior:

```text
scan repository
identify components missing from .releasepipeline.yml
produce proposed additions
produce a patch/diff
do not modify existing entries
```

## FR-35.3 — Apply mode

An explicit mode may eventually be supported:

```text
discover --scaffold --apply
```

Behavior:

```text
append approved/new component entries
never rewrite existing component fields
```

Applying modifications must require explicit user intent.

This operating model is recommended because it maintains the existing human-owned configuration contract while still supporting automation.

---

# 36. Newly Discovered Components

If a repository component exists but has no release-manifest entry, the discovery engine should propose a new component.

A proposal may contain only fields that can be supported by evidence.

For example:

```yaml
components:
  orders-api:
    path: apps/orders-api
    type: modern-dotnet
    tagPrefix: orders-api
    build:
      command: dotnet publish ./apps/orders-api -c Release -o .release-output/orders-api
    package:
      path: .release-output/orders-api
```

The proposal remains subject to human review.

---

# 37. `tagPrefix` Scaffolding

The current manifest assigns explicit `tagPrefix` values such as:

```text
web
api
desktop
```



Tag naming is partly release policy rather than a pure property of source code.

Therefore:

## FR-37.1

Discovery may propose a deterministic candidate `tagPrefix`.

## FR-37.2

A reasonable candidate may be derived from:

```text
existing component key
package/project name
normalized repository-relative component name
```

## FR-37.3

The candidate must be marked as scaffolded rather than discovered fact.

## FR-37.4

An existing `tagPrefix` must never be changed automatically.

---

# 38. Publishing Model

Artifact classification and publishing destination must remain separate.

Example:

```text
artifact type: container
destination: ghcr.io/example/api
```

The first may be discoverable from source.

The second is release policy.

This distinction is already visible in the current API configuration, where the manifest explicitly specifies a container adapter, image destination, Dockerfile, context, and OIDC setting.

---

# 39. Container Publishing Projection

When an existing or new component has explicit container release configuration, the projection may contain:

```yaml
publishing:
  adapter: container
  image: ...
  dockerfile: ...
  context: ...
  oidc: ...
```

Discovery may safely infer or propose:

```text
dockerfile
context
artifact type
```

where repository evidence is strong.

It must not infer:

```text
image destination
oidc policy
credentials
registry
```

unless these values are already explicit human-owned configuration.

---

# 40. npm Publishing Projection

The discovery model must support:

```text
artifactType = npm
```

independently of whether `.releasepipeline.yml` currently supports an npm publishing adapter.

A proposed future schema may use:

```yaml
publishing:
  adapter: npm
```

but the engine must not assume this is valid until the release manifest schema formally supports it.

The publish registry remains explicit configuration.

---

# 41. NuGet Publishing Projection

The discovery model must support:

```text
artifactType = nuget
```

independently of release-schema support.

A proposed future manifest representation may use:

```yaml
publishing:
  adapter: nuget
```

but this must be treated as a schema extension until formally adopted.

A NuGet feed must never be inferred.

---

# 42. Recommended Publishing Schema Extension

To support the stated goal of detecting npm and NuGet packages that need to be built and pushed, the release manifest should eventually support publication mechanisms separately from destinations.

Recommended conceptual model:

```yaml
publishing:
  adapter: npm
```

or:

```yaml
publishing:
  adapter: nuget
```

Destination-specific configuration should remain explicit and separate.

For example:

```yaml
publishing:
  adapter: npm
  registry: <human configured>
```

and:

```yaml
publishing:
  adapter: nuget
  feed: <human configured>
```

Discovery should be allowed to propose:

```text
adapter
```

but not:

```text
registry
feed
```

This extension remains a release-schema decision rather than a discovery-engine assumption.

---

# 43. Release Type Extension Policy

The discovery system must not couple its internal classification enum to `.releasepipeline.yml.type`.

Discovery may understand many project classes.

The release schema may intentionally understand only a small set.

Therefore:

```text
Discovery classification → explicit mapping → release type
```

must be configurable/versioned.

If a project such as a legacy .NET Framework application cannot map correctly to one of the currently supported types:

```text
node
modern-dotnet
modern-dotnet-windows
```

the result must be surfaced as:

```text
release type mapping unresolved
```

rather than assigning the nearest value.

---

# 44. Registry Neutrality

The engine must classify artifacts but must not decide where they should be published.

Examples of prohibited inferred destinations include:

```text
npmjs.org
GitHub Packages
Azure Artifacts
NuGet.org
GHCR
ACR
ECR
```

A registry URL discovered in repository files may be included as evidence but must not automatically become authoritative release configuration.

---

# 45. Error Handling

## FR-45.1 — Component-local errors

Failure to parse one project should generate an issue attached to that component or path.

The repository scan should continue where possible.

## FR-45.2 — Repository-fatal errors

Errors should fail the entire operation only when discovery cannot meaningfully proceed.

Examples might include:

```text
repository path does not exist
repository cannot be read
discovery output cannot be serialized
```

## FR-45.3 — Unsupported formats

Unsupported project formats should be reported rather than silently skipped when they appear to represent genuine components.

---

# 46. Diagnostics

The engine should distinguish diagnostic severity:

```text
info
warning
error
```

Examples:

```text
INFO:
Detected Vite React application.

WARNING:
Class library appears packable but explicit NuGet publication intent was not found.

WARNING:
Dockerfile may belong to either service-a or service-b.

ERROR:
Project file could not be parsed.
```

Diagnostics should include repository-relative paths.

---

# 47. Deterministic Output

Given:

```text
the same repository contents
the same configuration
the same discovery-engine version
```

the discovery output should be deterministic.

Ordering should not depend on filesystem traversal behavior.

Components, artifacts, and dependencies should be serialized in stable order.

---

# 48. Idempotency

Repeated discovery against an unchanged repository must not produce different scaffold proposals.

Repeated application of a scaffold operation must not duplicate component entries.

---

# 49. Performance

Discovery should avoid unnecessary expensive operations.

In particular, initial discovery should primarily inspect project metadata rather than:

```text
installing dependencies
compiling code
restoring packages
running application code
```

The engine must not require successful builds in order to discover project structure.

---

# 50. Security

Repository contents must be treated as untrusted input.

Discovery must not execute arbitrary repository scripts merely to determine project characteristics.

Examples that must not automatically run during discovery include:

```text
package.json scripts
MSBuild custom targets
shell scripts
PowerShell scripts
Docker builds
code generators
```

The engine may inspect these files as text/configuration.

Execution belongs to a separate trusted build phase.

---

# 51. Functional Acceptance Criteria

## AC-1 — Mixed monorepo

Given a repository containing:

```text
Vite React application
Next.js application
internal JavaScript library
publishable npm package
ASP.NET Core API
.NET Worker Service
.NET class library
NuGet package
legacy .NET Framework project
```

the engine discovers each project separately.

---

## AC-2 — React classification

Given React projects using different frameworks, the engine classifies them independently instead of assigning every package a generic React type.

---

## AC-3 — Generic JavaScript

Given a Node project with no React dependency, it is not classified as React.

---

## AC-4 — Legacy .NET

Given a valid non-SDK-style .NET Framework project, it is discovered and represented.

---

## AC-5 — .NET solution independence

Given a `.csproj` not included in any `.sln`, the project remains discoverable.

---

## AC-6 — npm package

Given a package with appropriate publication metadata and:

```json
{
  "private": false
}
```

the package may be classified as publishable.

---

## AC-7 — Private npm package

Given:

```json
{
  "private": true
}
```

the package must not be classified as externally publishable.

It may still be buildable.

---

## AC-8 — NuGet package

Given:

```xml
<IsPackable>true</IsPackable>
```

the project receives strong NuGet publication evidence.

---

## AC-9 — NuGet exclusion

Given:

```xml
<IsPackable>false</IsPackable>
```

the project must not be classified as a publishable NuGet package.

---

## AC-10 — Potential NuGet library

Given a normal SDK class library that can be packed but contains no explicit package intent, the engine may report:

```text
potential NuGet package
```

with lower confidence.

---

## AC-11 — Local Dockerfile

Given a Dockerfile colocated with an application and clearly building that application, the engine associates the container artifact with it.

---

## AC-12 — Shared Dockerfile

Given a root-level Dockerfile that clearly copies and builds one specific project, the engine associates it with that project.

---

## AC-13 — Ambiguous Dockerfile

Given a shared Dockerfile that could plausibly belong to multiple components, the engine preserves the ambiguity.

---

## AC-14 — Multiple artifacts

Given an ASP.NET project that can be published normally and containerized, the internal model represents both:

```text
dotnet-publish
container
```

---

## AC-15 — Workspace dependency

Given:

```text
web → shared-ui
```

through package workspace dependencies, the graph represents that relationship.

---

## AC-16 — .NET dependency

Given:

```xml
<ProjectReference Include="../Shared/Shared.csproj" />
```

the graph represents the project dependency.

---

## AC-17 — Transitive change impact

Given:

```text
App → Package A → Package B
```

and a change in Package B:

```text
Package B = directly affected
Package A = transitively affected
App       = transitively affected
```

---

## AC-18 — Watch path impact

Given a component with:

```yaml
watchPaths:
  - packages/shared
```

a change beneath `packages/shared` causes that component to be considered affected.

---

## AC-19 — Existing manifest preservation

Given an existing component:

```yaml
api:
  type: modern-dotnet-windows
```

and discovery concludes:

```text
modern-dotnet
```

the existing manifest value remains unchanged.

---

## AC-20 — Missing component

Given a newly added project with no `.releasepipeline.yml` entry, discovery includes it in the report and proposes a new scaffold entry.

---

## AC-21 — Rerun

Running scaffold generation twice does not create duplicate components.

---

## AC-22 — Registry neutrality

Given:

```text
old registry URLs
Docker image names
npm configuration
NuGet configuration
```

elsewhere in the repository, discovery does not automatically promote those values into a new component's publish destination.

---

## AC-23 — Build command evidence

Given an explicit JavaScript `build` script, discovery prefers a command invoking that script rather than inventing an unrelated build command.

---

## AC-24 — Test script semantics

Given only:

```text
lint
```

discovery may identify it as an available validation command but must not universally claim that it represents a unit-test suite.

---

## AC-25 — Unsupported release type

Given a discovered legacy .NET project for which no valid `.releasepipeline.yml.type` mapping exists, discovery reports the component and marks release projection as unresolved.

It does not invent a schema value.

---

# 52. Suggested Discovery Output Example

A discovery report might contain:

```json
{
  "schemaVersion": 1,
  "repository": {
    "root": "."
  },
  "components": [
    {
      "id": "web",
      "path": "apps/web",
      "ecosystem": "javascript",
      "classification": {
        "framework": "vite-react",
        "applicationKind": "spa"
      },
      "build": {
        "candidates": [
          {
            "command": "pnpm --filter ./apps/web build",
            "source": "explicit",
            "confidence": 1.0
          }
        ]
      },
      "artifacts": [
        {
          "type": "static-assets",
          "path": "apps/web/dist",
          "confidence": 0.98
        }
      ],
      "dependencies": [
        "shared"
      ],
      "releaseProjection": {
        "type": "node"
      },
      "evidence": []
    }
  ],
  "unresolved": []
}
```

This structure is illustrative rather than the final JSON Schema.

---

# 53. Suggested Release Projection Example

Given a new React application, discovery might propose:

```yaml
components:
  portal:
    path: apps/portal
    type: node
    tagPrefix: portal
    build:
      command: pnpm --filter ./apps/portal build
    package:
      path: apps/portal/dist
```

The rich framework classification remains in the discovery report rather than being written into the release manifest.

---

# 54. Suggested npm Package Projection

If the release schema adopts an npm publishing adapter, discovery could propose:

```yaml
components:
  shared-sdk:
    path: packages/shared-sdk
    type: node
    tagPrefix: shared-sdk
    build:
      command: pnpm --filter ./packages/shared-sdk build
    publishing:
      adapter: npm
```

Registry configuration would remain unset until supplied by human-owned configuration.

---

# 55. Suggested NuGet Package Projection

If the release schema adopts a NuGet publishing adapter:

```yaml
components:
  shared-contracts:
    path: packages/Shared.Contracts
    type: modern-dotnet
    tagPrefix: shared-contracts
    build:
      command: dotnet pack ./packages/Shared.Contracts -c Release -o .release-output/shared-contracts
    package:
      path: .release-output/shared-contracts
    publishing:
      adapter: nuget
```

Feed configuration would remain explicit.

---

# 56. Conceptual System Architecture

```text
                    Repository
                        │
                        ▼
              ┌──────────────────┐
              │ Discovery Engine │
              └──────────────────┘
                 │            │
                 │            │
                 ▼            ▼
        Discovery Report   Proposed Manifest
        + evidence         Changes / Patch
        + confidence             │
        + graph                  │
        + ambiguities            ▼
                           Human Review
                                │
                                ▼
                     .releasepipeline.yml
                                │
                                ▼
                     Provider Adapter Layer
                                │
                                ▼
                     Build / Test / Package
                                │
                                ▼
                          Publish / Deploy
```

Responsibility boundaries are:

```text
Discovery Engine
    understands the repository

.releasepipeline.yml
    declares release intent

Provider Adapter
    translates release intent into CI-provider behavior

Execution Layer
    performs builds, packaging, publication, and deployment
```

---

# 57. Open Release-Schema Decisions

The following items intentionally remain release-schema decisions rather than being silently assumed by discovery.

## OD-1 — Supported `type` values

The current manifest demonstrates:

```text
node
modern-dotnet
modern-dotnet-windows
```

It must be confirmed whether these are the complete supported set.

The discovery engine must remain capable of identifying projects that do not map to this set.

---

## OD-2 — npm publishing adapter

Decide whether the manifest formally supports:

```yaml
publishing:
  adapter: npm
```

This is recommended to support first-class npm package release configuration.

---

## OD-3 — NuGet publishing adapter

Decide whether the manifest formally supports:

```yaml
publishing:
  adapter: nuget
```

This is recommended for the same reason.

---

## OD-4 — `dependencies` semantics

Confirm that:

```yaml
dependencies:
  - shared
```

means a dependency on another release-pipeline component.

Once confirmed, discovery can project its dependency graph directly into this field.

---

## OD-5 — `tagPrefix` policy

Confirm whether automatically proposing the release component key as `tagPrefix` is an acceptable scaffolding convention.

Until then it should be treated as a proposal rather than discovered fact.

---

## OD-6 — Manifest application behavior

Recommended behavior is:

```text
discover
    report only

discover --scaffold
    produce proposed patch

discover --scaffold --apply
    explicitly append new entries
```

Existing entries remain immutable to discovery in all modes.

---

# 58. Implementation Readiness Criteria

This functional specification is ready to be converted into a coding-agent implementation prompt once the implementation phase defines:

```text
implementation language/runtime
final discovery JSON Schema
release-manifest schema/parser API
supported initial workspace systems
supported release type enum
whether npm/nuget adapters are being added now
CLI/API surface
test fixture strategy
```

None of these should alter the fundamental discovery architecture described by this document.

---

# 59. Summary Requirement

The system must discover repository structure aggressively but modify release intent conservatively.

It should:

```text
find broadly
classify precisely
infer transparently
retain evidence
model dependencies
calculate impact
propose configuration
preserve human decisions
avoid unsafe publishing guesses
remain CI-provider neutral
```

The core invariant is:

> **Discovery may propose what the repository appears capable of building and packaging; `.releasepipeline.yml` remains the authoritative human-owned declaration of what will actually be released.**

---

# 60. Repository Integration and Configuration Generation

## 60.1 Current implementation boundary

Discovery is a planned addition. The conceptual `discover` commands in section 35 are proposed interfaces, not commands currently available in this repository. Implementation shall use the repository's PowerShell tooling conventions and pnpm 12.3.4 when proposing JavaScript commands; recognizing another workspace format shall not install or introduce another package manager.

The following findings refine the draft's open decisions without changing existing execution behavior:

| Draft question | Current repository evidence and required treatment |
| --- | --- |
| OD-1: supported release types | The root configuration uses `node`, `modern-dotnet` and `modern-dotnet-windows`, but the build fallback also recognizes `legacy-dotnet-framework`. [ReleasePipeline.psm1](../ci/ReleasePipeline/ReleasePipeline.psm1) permits explicit build commands and contains the legacy adapter. Do not treat the root configuration's three examples as an exhaustive type enum. Validate each projection against actual parser and execution capabilities. |
| OD-2/OD-3: npm and NuGet adapters | [New-RegistryPublicationPlan.ps1](../ci/New-RegistryPublicationPlan.ps1) already recognizes `npm`, `nuget` and `container`; npm/NuGet require an explicit `publishing.endpoint`. The draft's `registry` and `feed` examples are conceptual, not adopted configuration keys. Discovery shall verify packaging and publication compatibility before producing an actionable projection; recognition by an adapter alone does not establish a complete package-release path. |
| OD-4: dependency semantics | `Test-ReleaseConfig` validates dependencies as existing component keys, rejects self-dependencies and cycles, and `Get-AffectedComponents` propagates changes to dependents. Thus `A.dependencies: [B]` means A depends on B for release impact. A discovery graph may include private/test/non-release projects that have no release key; these edges shall remain in the report unless a valid projection is available. Do not infer a guaranteed build order from impact propagation. |
| OD-5: tag prefixes | New tag prefixes remain deterministic scaffold proposals subject to review, with collision checks. Existing prefixes remain unchanged. |
| OD-6: application behavior | Default discovery is read-only; scaffold produces a proposal; explicit apply may create a new configuration or add approved missing components. The exact PowerShell command/parameter names remain an implementation decision. |

Discovery does not replace stable-tag-based release planning. Its changed-file analysis explains potential impact; the release engine continues to allocate versions and select release scope under the [current release requirements](FUNCTIONAL-REQUIREMENTS.md). Discovery shall not run implicitly during QA or PROD or alter a persisted release plan/configuration identity during recovery.

## 60.2 First-file generation and safe application

| ID | Requirement |
| --- | --- |
| FR-60.1 | When `.releasepipeline.yml` does not exist, scaffold mode shall generate a reviewable candidate document containing supported, evidence-backed component entries. It shall identify missing policy inputs and unresolved projections separately. It shall not silently create the authoritative file in discovery/scaffold mode. |
| FR-60.2 | A complete candidate shall obtain required non-discovery policy, including `versioning`, from explicit caller-supplied values or a caller-selected repository template. This is template composition, not inference. Discovery shall not guess `versioning`, `runtime` or `environments`. Without required policy, it shall return a partial proposal and actionable diagnostics rather than label the result ready to apply. |
| FR-60.3 | A proposal shall distinguish discovered projects, proposed release components, excluded/non-release projects and unresolved components. Test-only projects, private libraries and workspace-root orchestration packages shall remain visible without automatically becoming independent release entries solely because they were detected. |
| FR-60.4 | Before applying, the engine shall validate the candidate through the supported release configuration parser and check execution compatibility of proposed types, commands, output paths and publishing fields. Missing required values, unsupported mappings, duplicate keys/tag prefixes, unresolved dependency targets and cycles shall block the affected proposal from being represented as ready to apply. Validation shall not execute builds, scripts, restores or package publication. |
| FR-60.5 | Explicit apply shall create a missing `.releasepipeline.yml` only from a complete, valid, selected proposal. For an existing file it shall add only selected missing component entries; existing fields, comments, ordering and unrelated content shall be preserved. Watch-path recommendations shall remain separate suggestions rather than automatic edits to existing policy. |
| FR-60.6 | Apply shall verify that the target still matches the state against which the proposal was generated, including expected file absence for first creation. A concurrently created or edited file shall cause a conflict diagnostic rather than an overwrite. A failed validation/write shall leave the original file intact. Reapplying unchanged accepted additions shall produce no duplicates or further changes. |
| FR-60.7 | Candidate component keys and tag prefixes shall be deterministic and checked against existing and newly proposed entries. Ambiguous mappings, including several project files in one directory, shall require an explicit selection rather than silently combining projects or replacing an existing release identity. |
| FR-60.8 | Reports shall identify the discovery/schema version, repository-relative evidence, configuration input identity and proposal readiness. Confidence and command origin shall remain in the discovery report, not be inserted as unsupported `.releasepipeline.yml` fields. Unresolved destination or authentication policy shall never be emitted as executable placeholder publishing settings. |
| FR-60.9 | Traversal and parsing shall remain within the selected repository boundary, avoid recursive link/junction loops and generated/cache directories, and report inaccessible or unsafe paths. Dynamic configuration or MSBuild expressions that cannot be resolved statically shall remain unresolved; discovery shall not execute them to increase confidence. |

Explicit apply intent is an operating-mode requirement for the future engine, not a requirement to ask for approval when editing this requirements document.

## 60.3 Additional acceptance criteria

These supplement AC-1 through AC-25; they are planned validation scenarios, not completed tests.

| ID | Scenario | Expected result |
| --- | --- | --- |
| AC-26 | Scan the current repository from `apps/web`. | Resolve the repository root; identify web, API, desktop and other genuine project/package candidates; match configured components to their existing keys; preserve API publishing settings and web validation/watch paths. |
| AC-27 | Scaffold a repository without `.releasepipeline.yml`, with explicit policy/template inputs. | Produce a complete candidate and readable diff; the target remains absent until explicit apply; the selected valid proposal can then create it. |
| AC-28 | Scaffold without required policy or with unknown artifact outputs. | Emit a partial proposal and field-level diagnostics; do not invent release policy/output paths or apply an incomplete entry. |
| AC-29 | Add a project to a repository with a customized existing manifest. | Propose only missing release entries. Apply preserves existing fields, comments and unrelated content; a repeat produces no change. |
| AC-30 | Change/create the target after proposal generation, or encounter a write failure. | Report a conflict/failure and preserve the current target without partial replacement. |
| AC-31 | Encounter duplicate candidate names, a dependency cycle, or a dependency on a private package without a release key. | Retain findings in the report; do not emit colliding keys, a cyclic configuration or dangling release dependencies as ready to apply. |
| AC-32 | Scan malformed projects, dynamic configuration and scripts containing executable side effects. | Continue unrelated discovery, retain diagnostics/ambiguities and execute no repository code. |
| AC-33 | Repeat a scan with identical contents, inputs and engine version. | Produce stable component ordering, identities, evidence and scaffold proposals. |
| AC-34 | Discover npm/NuGet or legacy .NET candidates. | Use verified adapter/type capabilities and actual configuration keys; require explicit publication endpoints and valid packaging; preserve unsupported details as unresolved findings. |

## 60.4 Remaining implementation decisions

Before implementation, define the versioned discovery JSON Schema, PowerShell CLI/API, initial classification coverage, static configuration parsing limits, confidence rules, template-selection interface, comment-preserving YAML editing approach and fixture strategy. The existing release adapters and parser must be assessed before adding schema extensions. These decisions shall preserve the supplied specification's evidence, neutrality and human-ownership guarantees.
