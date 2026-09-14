# Provider mappings

The release engine is provider-neutral. A CI provider is responsible for checkout, runner selection, authentication, artifact transfer, and approvals; the PowerShell scripts remain responsible for planning, building, packaging, promotion, and tag safety.

The normalized inputs are:

| Normalized input | PowerShell parameter | Meaning |
| --- | --- | --- |
| Branch | `-Branch` | Source branch channel (`dev`, `qa`, or `main`) |
| Base ref | `-BaseRef` | Ref used for changed-file detection |
| Version bump | `-VersionBump` | `major`, `minor`, or `patch` |
| Component overrides | `-ComponentOverridesJson` | JSON map such as `{"api":"patch"}` |
| Exact versions | `-ExactVersionsJson` | JSON map such as `{"api":"2.4.0"}` |
| Release all | `-ReleaseAll` | Explicitly release every configured component |
| CI run ID | `-CiRunId` | Provider run/build identifier for provenance |

## Azure DevOps

Use a Windows agent and a PowerShell task. Pipeline variables are mapped at the provider boundary; release logic stays in `eng/ci`.

```yaml
trigger:
- dev
- qa
- main

pool:
  vmImage: windows-latest

variables:
  versionBump: minor
  componentOverrides: '{}'
  exactVersions: '{}'
  releaseAll: false
  releaseChannel: beta
  ${{ if eq(variables['Build.SourceBranchName'], 'qa') }}:
    releaseChannel: rc
  ${{ if eq(variables['Build.SourceBranchName'], 'main') }}:
    releaseChannel: stable

stages:
- stage: Package
  jobs:
  - job: package
    steps:
    - checkout: self
      fetchDepth: 0
      fetchTags: true
    - powershell: |
        Install-Module powershell-yaml -Scope CurrentUser -Force
        Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force
        .\eng\ci\Invoke-ReleasePipelineTests.ps1
      displayName: Test release engine
    - powershell: |
        .\eng\ci\New-ReleasePlan.ps1 `
          -Branch "$(Build.SourceBranchName)" `
          -BaseRef "$(Build.SourceVersion)^" `
          -CiRunId "$(Build.BuildId)" `
          -VersionBump "$(versionBump)" `
          -ComponentOverridesJson '$(componentOverrides)' `
          -ExactVersionsJson '$(exactVersions)' `
          -ReleaseAll:([bool]::Parse('$(releaseAll)'))
      displayName: Plan release
    - powershell: .\eng\ci\Invoke-ReleasePackage.ps1 -PlanPath .\release-plan.json
      displayName: Build and package
    - publish: $(Build.SourcesDirectory)/release-plan.json
      artifact: release-plan
    - publish: $(Build.SourcesDirectory)/artifacts
      artifact: release-artifacts

- stage: Release
  dependsOn: Package
  condition: succeeded()
  # Add an Azure DevOps environment with an approval check here.
  jobs:
  - deployment: createTags
    environment: release-$(releaseChannel)
    strategy:
      runOnce:
        deploy:
          steps:
          - checkout: self
            fetchDepth: 0
            fetchTags: true
          - download: current
            artifact: release-plan
          - powershell: |
              .\eng\ci\New-ReleaseTags.ps1 `
                -PlanPath "$(Pipeline.Workspace)/release-plan/release-plan.json" `
                -Push
            displayName: Create release tags
```

For Azure DevOps, mirror the GitHub environment set: `development`, `beta`, `qa`, `qa-approval`, `rc`, and `production`. Put the human approval check on `qa-approval` only, and make the approval reference the persisted release identity (release id, candidate SHA, artifact digest) rather than a branch name. Use a separate deployment job for registry publication with only the permissions and service connection required by that registry. Do not place registry credentials in script arguments or pipeline command text.

Azure DevOps uses `Build.SourceBranchName`, `Build.SourceVersion`, and `Build.BuildId` for the normalized branch, commit, and run ID. If the provider does not expose a suitable run ID, use the provider’s immutable build number instead. Pass `Build.SourceVersion` to `Assert-CandidateCommit.ps1` at the start of the candidate stage, and to `New-ReleaseManifest.ps1` as `-CandidateSha`; every later stage then reads `release-manifest.json` instead of the repository.

## Jenkins

Use a Windows agent with the PowerShell plugin or invoke `pwsh` from a `bat`/PowerShell step. The `input` step is the approval boundary; it must occur after packaging and before tag creation.

The repository includes ready-to-use [`Jenkinsfile`](../Jenkinsfile) and [`Jenkinsfile.promote`](../Jenkinsfile.promote) definitions. The first expects a multibranch or pipeline job that checks out the repository; the second expects the Copy Artifact plugin so it can retrieve a specific successful source build without rebuilding it.

```groovy
pipeline {
  agent { label 'windows' }

  parameters {
    choice(name: 'VERSION_BUMP', choices: ['minor', 'patch', 'major'])
    string(name: 'COMPONENT_OVERRIDES', defaultValue: '{}')
    string(name: 'EXACT_VERSIONS', defaultValue: '{}')
    booleanParam(name: 'RELEASE_ALL', defaultValue: false)
  }

  stages {
    stage('Plan and package') {
      steps {
        checkout([$class: 'GitSCM', branches: scm.branches,
          userRemoteConfigs: scm.userRemoteConfigs,
          extensions: [[$class: 'CloneOption', depth: 0, noTags: false]]])
        powershell '''
          Install-Module powershell-yaml -Scope CurrentUser -Force
          Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force
          .\\eng\\ci\\Invoke-ReleasePipelineTests.ps1
          .\\eng\\ci\\New-ReleasePlan.ps1 `
            -Branch "$env:BRANCH_NAME" `
            -CiRunId "$env:BUILD_TAG" `
            -VersionBump "$env:VERSION_BUMP" `
            -ComponentOverridesJson "$env:COMPONENT_OVERRIDES" `
            -ExactVersionsJson "$env:EXACT_VERSIONS" `
            -ReleaseAll:([bool]::Parse("$env:RELEASE_ALL"))
          .\\eng\\ci\\Invoke-ReleasePackage.ps1 -PlanPath .\\release-plan.json
        '''
        archiveArtifacts artifacts: 'release-plan.json,artifacts/**', fingerprint: true
      }
    }

    stage('Review release') {
      steps {
        input message: 'Review release-plan.json and approve tag creation',
              submitter: 'release-managers'
      }
    }

    stage('Create tags') {
      steps {
        powershell '.\\eng\\ci\\New-ReleaseTags.ps1 -PlanPath .\\release-plan.json -Push'
      }
    }
  }
}
```

Jenkins credentials should be provided through a credential binding or Git credential helper. Keep the tag-push credential scoped to the tag stage and keep registry credentials scoped to a separate publication stage. The `input` step provides a human approval, while Jenkins folder or multibranch permissions determine who may approve it.

## Promotion mapping

Promotion consumes the retained source provenance and never rebuilds the component:

```powershell
.\eng\ci\New-ArtifactPromotionPlan.ps1 `
  -ProvenancePath .\source-artifacts\artifacts\provenance.json `
  -TargetChannel rc
.\eng\ci\Invoke-ArtifactPromotion.ps1 -PlanPath .\promotion-plan.json -Push
```

The provider must transfer the complete source artifact directory, including `artifacts/provenance.json`, and the promotion plan/record. An approval must happen before the tag-push step. Registry publication can then consume the same source provenance with `New-RegistryPublicationPlan.ps1 -PromotionPlanPath promotion-plan.json`.

## Provider adapter checklist

- Use a full checkout with tags; shallow history is insufficient for version calculation.
- Install `powershell-yaml` and the pinned Pester version on the Windows runner.
- Upload `release-plan.json`, `artifacts/`, and provenance as immutable build artifacts.
- Review the plan before running `New-ReleaseTags.ps1 -Push`.
- Give only the tag stage write permission to repository refs.
- Authenticate registries through OIDC, service connections, or credential helpers.
- Retry the workflow using the same plan only when the tag and artifact are still valid; regenerate a plan after a conflicting tag or changed commit.
