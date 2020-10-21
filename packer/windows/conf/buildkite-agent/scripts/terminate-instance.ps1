# Stop script execution when a non-terminating error occurs
$ErrorActionPreference = "Stop"

Write-Output "terminate-instance: waiting for 10 seconds to allow agent logs to drain to Cloudwatch..."
Start-Sleep -Seconds 10

$InstanceId = (Invoke-WebRequest -UseBasicParsing http://169.254.169.254/latest/meta-data/instance-id).content
$Region = (Invoke-WebRequest -UseBasicParsing http://169.254.169.254/latest/meta-data/placement/availability-zone).content -replace ".$"

Write-Output "terminate-instance: requesting instance termination..."
aws autoscaling terminate-instance-in-auto-scaling-group --region "$Region" --instance-id "$InstanceId" "--should-decrement-desired-capacity"

if ($lastexitcode -eq 0) { # If autoscaling request was successful, we will terminate
  Write-Output "terminate-instance: disabling buildkite-agent service"
  nssm stop buildkite-agent
}
else {
  Write-Output "terminate-instance: ASG could not decrement (we're already at minSize)"
}
