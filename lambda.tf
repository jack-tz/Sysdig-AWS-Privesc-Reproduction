# lambda.tf
# Execution role with admin perms — this is the linchpin of the privesc.
# In the real attack the role had IAM-write capability; we use AdminAccess
# for simplicity, but you can scope it down to just iam:CreateAccessKey if
# you want a cleaner experiment.
resource "aws_iam_role" "lambda_exec" {
  name = "EC2-init-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_exec_admin" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

data "archive_file" "placeholder" {
  type        = "zip"
  output_path = "${path.module}/placeholder.zip"
  source {
    filename = "index.py"
    content  = "def lambda_handler(event, context):\n    return {'statusCode': 200, 'body': 'ok'}\n"
  }
}

resource "aws_lambda_function" "ec2_init" {
  function_name    = "EC2-init"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.lambda_handler"
  runtime          = "python3.11"
  filename         = data.archive_file.placeholder.output_path
  source_code_hash = data.archive_file.placeholder.output_base64sha256
}