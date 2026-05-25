# s3.tf
resource "random_id" "suffix" { byte_length = 4 }

resource "aws_s3_bucket" "rag_data" {
  bucket        = "rag-data-${random_id.suffix.hex}"
  force_destroy = true
}

# Explicitly disable the Block Public Access guardrails — this is the
# misconfiguration. Modern AWS accounts block this by default.
resource "aws_s3_bucket_public_access_block" "rag_data" {
  bucket                  = aws_s3_bucket.rag_data.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "public_read" {
  bucket     = aws_s3_bucket.rag_data.id
  depends_on = [aws_s3_bucket_public_access_block.rag_data]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicRead"
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.rag_data.arn,
        "${aws_s3_bucket.rag_data.arn}/*"
      ]
    }]
  })
}

# Drop the foothold credentials in the public bucket — mirrors the
# Sysdig finding that credentials were in public RAG buckets.
resource "aws_s3_object" "creds" {
  bucket  = aws_s3_bucket.rag_data.id
  key     = "config/aws-credentials.txt"
  content = <<-EOF
    [default]
    aws_access_key_id=${aws_iam_access_key.compromised.id}
    aws_secret_access_key=${aws_iam_access_key.compromised.secret}
  EOF
}