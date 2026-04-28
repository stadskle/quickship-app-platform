output "user_name" {
  value       = aws_iam_user.dev.name
  description = "IAM user name. Used by quickship modules to attach per-app managed policies."
}

output "user_arn" {
  value       = aws_iam_user.dev.arn
  description = "IAM user ARN."
}

output "create_access_key_command" {
  description = "Run this (as platform admin) after `terraform apply` to mint an access key for the developer. Capture the AccessKeyId + SecretAccessKey from the output and hand them to the developer over a secure channel. Re-run to rotate (after deleting the old key)."
  value       = "aws iam create-access-key --user-name ${aws_iam_user.dev.name}"
}

output "developer_setup_command" {
  description = "Send this command to the developer along with their access keys. They run it once to configure their local AWS profile."
  value       = "aws configure --profile ${var.name_prefix}"
}
