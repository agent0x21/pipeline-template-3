pipeline {
  agent { label 'windows' }

  options {
    disableConcurrentBuilds()
    timestamps()
  }

  parameters {
    choice(name: 'VERSION_BUMP', choices: ['minor', 'patch', 'major'], description: 'Version bump for changed components')
    string(name: 'COMPONENT_OVERRIDES', defaultValue: '{}', description: 'JSON component bump map')
    string(name: 'EXACT_VERSIONS', defaultValue: '{}', description: 'JSON exact-version map')
    booleanParam(name: 'RELEASE_ALL', defaultValue: false, description: 'Release every configured component')
  }

  environment {
    CONFIG_PATH = '.releasepipeline.yml'
    CI_RUN_ID = "jenkins-${env.JOB_NAME}-${env.BUILD_NUMBER}"
  }

  stages {
    stage('Checkout') {
      steps {
        // Configure the Jenkins Git SCM with credentials that can read the repo.
        checkout scm
        powershell '''
          $ErrorActionPreference = 'Stop'
          git fetch --tags --force
          foreach ($tool in @('git', 'pwsh', 'dotnet', 'node')) {
            if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required tool not found: $tool" }
          }
        '''
      }
    }

    stage('Test release engine') {
      steps {
        powershell '''
          Install-Module powershell-yaml -Scope CurrentUser -Force
          Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force
          .\\eng\\ci\\Invoke-ReleasePipelineTests.ps1
        '''
      }
    }

    stage('Plan release') {
      steps {
        powershell '''
          $branch = if ($env:BRANCH_NAME) { $env:BRANCH_NAME } else { (git branch --show-current).Trim() }
          .\\eng\\ci\\New-ReleasePlan.ps1 `
            -ConfigPath $env:CONFIG_PATH `
            -Branch $branch `
            -BaseRef 'HEAD~1' `
            -CiRunId $env:CI_RUN_ID `
            -VersionBump $env:VERSION_BUMP `
            -ComponentOverridesJson $env:COMPONENT_OVERRIDES `
            -ExactVersionsJson $env:EXACT_VERSIONS `
            -ReleaseAll:([bool]::Parse($env:RELEASE_ALL))
        '''
      }
    }

    stage('Build and package') {
      steps {
        powershell '.\\eng\\ci\\Invoke-ReleasePackage.ps1 -PlanPath .\\release-plan.json'
      }
      post {
        success {
          archiveArtifacts artifacts: 'release-plan.json,artifacts/**', fingerprint: true, onlyIfSuccessful: true
        }
      }
    }

    stage('Review release plan') {
      steps {
        input message: 'Review release-plan.json and approve tag creation', submitter: 'release-managers'
      }
    }

    stage('Create release tags') {
      steps {
        // The Jenkins Git checkout must have push credentials configured for origin.
        powershell '.\\eng\\ci\\New-ReleaseTags.ps1 -PlanPath .\\release-plan.json -Push'
      }
    }

    stage('Review registry publication') {
      steps {
        input message: 'Approve registry publication for this release', submitter: 'release-managers'
      }
    }

    stage('Publish registry artifacts') {
      steps {
        powershell '''
          .\\eng\\ci\\New-RegistryPublicationPlan.ps1 `
            -ProvenancePath .\\artifacts\\provenance.json `
            -ConfigPath $env:CONFIG_PATH `
            -OutputPath .\\registry-publication-plan.json
          .\\eng\\ci\\Publish-RegistryArtifacts.ps1 `
            -PlanPath .\\registry-publication-plan.json `
            -OutputPath .\\registry-publication.json
        '''
      }
      post {
        always {
          archiveArtifacts artifacts: 'registry-publication-plan.json,registry-publication.json', allowEmptyArchive: true, fingerprint: true
        }
      }
    }
  }
}
