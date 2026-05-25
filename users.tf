# users.tf
# The "compromised" foothold — modelled on the Sysdig description:
# ReadOnlyAccess for enumeration + dangerous Lambda permissions.
resource "aws_iam_user" "compromised" {
  name = "compromised_user"
}

resource "aws_iam_access_key" "compromised" {
  user = aws_iam_user.compromised.name
}

resource "aws_iam_user_policy_attachment" "compromised_readonly" {
  user       = aws_iam_user.compromised.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# The dangerous bit: ability to overwrite any Lambda's code.
# Note Resource = "*" — this is the over-permissioning that matters.
resource "aws_iam_user_policy" "compromised_lambda" {
  name = "lambda-update-code"
  user = aws_iam_user.compromised.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:InvokeFunction",
        "lambda:GetFunction",
      ]
      Resource = "*"
    }]
  })
}

# The admin target user — the privesc destination.
resource "aws_iam_user" "frick" {
  name = "frick"
}

resource "aws_iam_user_policy_attachment" "frick_admin" {
  user       = aws_iam_user.frick.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}