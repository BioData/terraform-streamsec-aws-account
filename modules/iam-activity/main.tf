data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "streamsec_host" "this" {}
data "streamsec_aws_account" "this" {
  cloud_account_id = data.aws_caller_identity.current.account_id
}

locals {
  lambda_source_code_bucket = "${var.lambda_source_code_bucket_prefix}-${data.aws_region.current.name}"

  compatible_runtimes = formatlist(var.lambda_runtime)
}

################################################################################
# IAM Activity Lambda
################################################################################

resource "aws_iam_role" "lambda_execution_role" {
  name        = var.lambda_iam_role_use_name_prefix ? null : var.lambda_iam_role_name
  name_prefix = var.lambda_iam_role_use_name_prefix ? var.lambda_iam_role_name : null
  path        = var.lambda_iam_role_path
  description = var.lambda_iam_role_description

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
  tags = merge(var.tags, var.lambda_iam_role_tags)
}

resource "aws_iam_policy" "lambda_exec_policy" {
  name        = var.lambda_policy_use_name_prefix ? null : var.lambda_policy_name
  name_prefix = var.lambda_policy_use_name_prefix ? var.lambda_policy_name : null
  description = var.lambda_policy_description
  path        = var.lambda_policy_path

  policy = jsonencode({
    "Version" : "2012-10-17"
    "Statement" : [
      {
        Action = [
          "secretsmanager:GetSecretValue"
        ],
        Effect   = "Allow",
        Resource = "arn:aws:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:${var.collection_iam_activity_token_secret_name}*"
      },
      # s3 permissions
      {
        Action = [
          "s3:GetObject",
        ],
        Effect = "Allow",
        Resource = [
          data.aws_s3_bucket.iam_activity_bucket.arn,
          "${data.aws_s3_bucket.iam_activity_bucket.arn}/*"
        ]
      },
    ]

  })

  tags = merge(var.tags, var.iam_policy_tags)
}

resource "aws_iam_role_policy_attachment" "lambda_execution_role_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_execution_role.name
}

resource "aws_iam_role_policy_attachment" "lambda_exec_policy_attachment" {
  policy_arn = aws_iam_policy.lambda_exec_policy.arn
  role       = aws_iam_role.lambda_execution_role.name
}

resource "aws_secretsmanager_secret" "streamsec_collection_secret" {
  name                    = var.collection_iam_activity_token_secret_name
  description             = "Stream Security Collection Token"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "streamsec_collection_secret_version" {
  secret_id     = aws_secretsmanager_secret.streamsec_collection_secret.id
  secret_string = data.streamsec_aws_account.this.streamsec_collection_token
}


resource "aws_lambda_layer_version" "streamsec_lambda_layer" {
  s3_bucket           = local.lambda_source_code_bucket
  s3_key              = var.lambda_layer_s3_source_code_key
  layer_name          = var.lambda_layer_name
  compatible_runtimes = local.compatible_runtimes
}

resource "aws_lambda_function" "streamsec_iam_activity_lambda" {
  function_name = var.lambda_name
  role          = aws_iam_role.lambda_execution_role.arn
  handler       = "src/handler.s3Collector"
  runtime       = var.lambda_runtime
  memory_size   = var.lambda_cloudwatch_memory_size
  timeout       = var.lambda_cloudwatch_timeout
  s3_bucket     = local.lambda_source_code_bucket
  s3_key        = var.lambda_cloudwatch_s3_source_code_key
  layers        = [aws_lambda_layer_version.streamsec_lambda_layer.arn]

  vpc_config {
    subnet_ids         = var.lambda_subnet_ids
    security_group_ids = var.lambda_security_group_ids
  }

  environment {
    variables = {
      API_TOKEN   = var.collection_iam_activity_token_secret_name
      SECRET_NAME = var.collection_iam_activity_token_secret_name
      API_URL     = data.streamsec_host.this.url
      BATCH_SIZE  = var.lambda_batch_size
      ENV         = "production"
      NODE_ENV    = "production"
    }
  }

  tags = merge(var.tags, var.lambda_tags)
}

resource "aws_lambda_function_event_invoke_config" "streamsec_options_cloudwatch" {
  function_name                = aws_lambda_function.streamsec_iam_activity_lambda.function_name
  maximum_event_age_in_seconds = var.lambda_cloudwatch_max_event_age
  maximum_retry_attempts       = var.lambda_cloudwatch_max_retry
}

resource "aws_lambda_permission" "streamsec_iam_activity_allow_s3_invoke" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.streamsec_iam_activity_lambda.arn
  principal     = "s3.amazonaws.com"
  source_arn    = data.aws_s3_bucket.iam_activity_bucket.arn
}


################################################################################
# IAM Activity S3
################################################################################

data "aws_s3_bucket" "iam_activity_bucket" {
  bucket = var.iam_activity_bucket_name
}

resource "aws_s3_bucket_notification" "iam_activity_s3_lambda_trigger" {
  count  = var.iam_activity_s3_eventbridge_trigger ? 0 : 1
  bucket = data.aws_s3_bucket.iam_activity_bucket.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.streamsec_iam_activity_lambda.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.streamsec_iam_activity_allow_s3_invoke]
}

moved {
  from = aws_s3_bucket_notification.iam_activity_s3_lambda_trigger
  to   = aws_s3_bucket_notification.iam_activity_s3_lambda_trigger[0]
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  count       = var.iam_activity_s3_eventbridge_trigger ? 1 : 0
  bucket      = data.aws_s3_bucket.iam_activity_bucket.id
  eventbridge = true
}

resource "aws_cloudwatch_event_rule" "iam_activity_s3_eventbridge_trigger" {
  count       = var.iam_activity_s3_eventbridge_trigger ? 1 : 0
  name        = var.iam_activity_s3_eventbridge_rule_name
  description = var.iam_activity_s3_eventbridge_rule_description
  event_pattern = jsonencode({
    source      = ["aws.s3"],
    detail-type = ["Object Created"],
    detail = {
      bucket = {
        name = [var.iam_activity_bucket_name]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "iam_activity_s3_eventbridge_target" {
  count = var.iam_activity_s3_eventbridge_trigger ? 1 : 0
  rule  = aws_cloudwatch_event_rule.iam_activity_s3_eventbridge_trigger[0].name
  arn   = aws_lambda_function.streamsec_iam_activity_lambda.arn
}

resource "aws_lambda_permission" "iam_activity_s3_allow_invoke" {
  count         = var.iam_activity_s3_eventbridge_trigger ? 1 : 0
  statement_id  = "AllowInvocationFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.streamsec_iam_activity_lambda.arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.iam_activity_s3_eventbridge_trigger[0].arn
}
