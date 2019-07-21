## Installs the Buildkite Agent, run from the CloudFormation template

Set-PSDebug -Trace 2

# Stop script execution when a non-terminating error occurs
$ErrorActionPreference = "Stop"

function on_error {
  $errorLine=$_.InvocationInfo.ScriptLineNumber
  $errorMessage=$_.Exception

  aws autoscaling set-instance-health `
    --instance-id "(Invoke-WebRequest -UseBasicParsing http://169.254.169.254/latest/meta-data/instance-id).content" `
    --health-status Unhealthy

  cfn-signal `
    --region "$Env:AWS_REGION" `
    --stack "$Env:BUILDKITE_STACK_NAME" `
    --reason "Error on line ${errorLine}: $errorMessage" `
    --resource "AgentAutoScaleGroup" `
    --exit-code 1
}

trap {on_error}

$Env:INSTANCE_ID=(Invoke-WebRequest -UseBasicParsing http://169.254.169.254/latest/meta-data/instance-id).content
$DOCKER_VERSION=(docker --version).split(" ")[2].Replace(",","")

$PLUGINS_ENABLED=@()
If ($Env:SECRETS_PLUGIN_ENABLED -eq "true") { $PLUGINS_ENABLED += "secrets" }
If ($Env:ECR_PLUGIN_ENABLED -eq "true") { $PLUGINS_ENABLED += "ecr" }
If ($Env:DOCKER_LOGIN_PLUGIN_ENABLED -eq "true") { $PLUGINS_ENABLED += "docker-login" }

# cfn-env is sourced by the environment hook in builds
Set-Content -Path C:\buildkite-agent\cfn-env -Value @"
export DOCKER_VERSION=$DOCKER_VERSION
export BUILDKITE_STACK_NAME=$Env:BUILDKITE_STACK_NAME
export BUILDKITE_STACK_VERSION=$Env:BUILDKITE_STACK_VERSION
export BUILDKITE_AGENTS_PER_INSTANCE=$Env:BUILDKITE_AGENTS_PER_INSTANCE
export BUILDKITE_SECRETS_BUCKET=$Env:BUILDKITE_SECRETS_BUCKET
export AWS_DEFAULT_REGION=$Env:AWS_REGION
export AWS_REGION=$Env:AWS_REGION
export PLUGINS_ENABLED="$PLUGINS_ENABLED"
export BUILDKITE_ECR_POLICY=$Env:BUILDKITE_ECR_POLICY
"@

If ($Env:BUILDKITE_AGENT_RELEASE -eq "edge") {
  Write-Output "Downloading buildkite-agent edge..."
  Invoke-WebRequest -OutFile C:\buildkite-agent\bin\buildkite-agent-edge.exe -Uri "https://download.buildkite.com/agent/experimental/latest/buildkite-agent-windows-amd64.exe"
  buildkite-agent-edge.exe --version
}

Copy-Item -Path C:\buildkite-agent\bin\buildkite-agent-${Env:BUILDKITE_AGENT_RELEASE}.exe -Destination C:\buildkite-agent\bin\buildkite-agent.exe

$agent_metadata=@(
  "queue=${Env:BUILDKITE_QUEUE}"
  "docker=${DOCKER_VERSION}"
  "stack=${Env:BUILDKITE_STACK_NAME}"
  "buildkite-aws-stack=${Env:BUILDKITE_STACK_VERSION}"
)

If (Test-Path Env:BUILDKITE_AGENT_TAGS) {
  $agent_metadata += $Env:BUILDKITE_AGENT_TAGS.split(",")
}

# Enable git mirrors
If ($Env:BUILDKITE_AGENT_ENABLE_GIT_MIRRORS_EXPERIMENT -eq "true") {
  If ([string]::IsNullOrEmpty($Env:BUILDKITE_AGENT_EXPERIMENTS)) {
    $Env:BUILDKITE_AGENT_EXPERIMENTS = "git-mirrors"
  }
  Else {
    $Env:BUILDKITE_AGENT_EXPERIMENTS += ",git-mirrors"
  }
}

# If the agent token path is set, use that instead of BUILDKITE_AGENT_TOKEN
If (![string]::IsNullOrEmpty($Env:BUILDKITE_AGENT_TOKEN_PATH)) {
    $Env:BUILDKITE_AGENT_TOKEN = aws ssm get-parameter --name ${Env:BUILDKITE_AGENT_TOKEN_PATH} --with-decryption | jq -r .Parameter.Value
}

$OFS=","
Set-Content -Path C:\buildkite-agent\buildkite-agent.cfg -Value @"
name="${Env:BUILDKITE_STACK_NAME}-${Env:INSTANCE_ID}-%n"
token="${Env:BUILDKITE_AGENT_TOKEN}"
tags=$agent_metadata
tags-from-ec2=true
timestamp-lines=${Env:BUILDKITE_AGENT_TIMESTAMP_LINES}
hooks-path="C:\buildkite-agent\hooks"
build-path="C:\buildkite-agent\builds"
plugins-path="C:\buildkite-agent\plugins"
git-mirrors-path="C:\buildkite-agent\git-mirrors"
experiment="${Env:BUILDKITE_AGENT_EXPERIMENTS}"
priority=%n
spawn=${Env:BUILDKITE_AGENTS_PER_INSTANCE}
no-color=true
shell=powershell
disconnect-after-idle-timeout=${Env:BUILDKITE_SCALE_IN_IDLE_PERIOD}
disconnect-after-job=${Env:BUILDKITE_TERMINATE_INSTANCE_AFTER_JOB}
"@
$OFS=" "

nssm set lifecycled AppEnvironmentExtra :AWS_REGION=$Env:AWS_REGION
nssm set lifecycled AppEnvironmentExtra +LIFECYCLED_HANDLER="C:\buildkite-agent\bin\stop-agent-gracefully.ps1"
Restart-Service lifecycled

# wait for docker to start
$next_wait_time=0
do {
  Write-Output "Sleeping $next_wait_time seconds"
  Start-Sleep -Seconds ($next_wait_time++)
  docker ps
} until ($? -OR ($next_wait_time -eq 5))

docker ps
if (! $?) {
  echo "Failed to contact docker"
  exit 1
}

# prevent password from being revealed by debug tracing
Set-PSDebug -Trace 0

Write-Output "Creating buildkite-agent user account in Administrators group"

$Count = Get-Random -min 24 -max 32
$Password = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count $Count | ForEach-Object {[char]$_})
$UserName = "buildkite-agent"

New-LocalUser -Name $UserName -PasswordNeverExpires -Password ($Password | ConvertTo-SecureString -AsPlainText -Force) | out-null

If ($Env:BUILDKITE_WINDOWS_ADMINISTRATOR -eq "true") {
  Add-LocalGroupMember -Group "Administrators" -Member $UserName | out-null
}

If (![string]::IsNullOrEmpty($Env:BUILDKITE_ELASTIC_BOOTSTRAP_SCRIPT)) {
  Write-Output "Running the elastic bootstrap script"
  C:\buildkite-agent\bin\bk-fetch.ps1 -From "$Env:BUILDKITE_ELASTIC_BOOTSTRAP_SCRIPT" -To C:\buildkite-agent\elastic_bootstrap.ps1
  C:\buildkite-agent\elastic_bootstrap.ps1
  Remove-Item -Path C:\buildkite-agent\elastic_bootstrap.ps1
}

Write-Output "Starting the Buildkite Agent"

nssm install buildkite-agent C:\buildkite-agent\bin\buildkite-agent.exe start
nssm set buildkite-agent ObjectName .\$UserName $Password
nssm set buildkite-agent AppStdout C:\buildkite-agent\buildkite-agent.log
nssm set buildkite-agent AppStderr C:\buildkite-agent\buildkite-agent.log
nssm set buildkite-agent AppEnvironmentExtra :HOME=C:\buildkite-agent
nssm set buildkite-agent AppExit Default Exit
nssm set buildkite-agent AppEvents Exit/Post "powershell C:\buildkite-agent\bin\terminate-instance.ps1"

Restart-Service buildkite-agent

# renable debug tracing
Set-PSDebug -Trace 2

# let the stack know that this host has been initialized successfully
cfn-signal `
  --region "$Env:AWS_REGION" `
  --stack "$Env:BUILDKITE_STACK_NAME" `
  --resource "AgentAutoScaleGroup" `
  --exit-code 0 ; if (-not $?) {
    # This will fail if the stack has already completed, for instance if there is a min size
    # of 1 and this is the 2nd instance. This is ok, so we just ignore the erro
    echo "Signal failed"
  }

Set-PSDebug -Off
