# outputs.tf
output "bucket"           { value = aws_s3_bucket.rag_data.id }
output "public_creds_url" { value = "https://${aws_s3_bucket.rag_data.id}.s3.amazonaws.com/config/aws-credentials.txt" }