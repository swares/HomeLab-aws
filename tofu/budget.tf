# Backstop for the forgotten-cluster failure mode. The nightly teardown timer
# is the primary control; this is what catches the night the timer did not run.

resource "aws_sns_topic" "alerts" {
  name = "${var.cluster_name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.budget_email
  # NOTE: AWS sends a confirmation email. Until you click it the subscription
  # sits PendingConfirmation and delivers nothing. Confirm it on first apply
  # or the budget alarm is decorative.
}

resource "aws_budgets_budget" "monthly" {
  name         = "${var.cluster_name}-monthly"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 50% actual: something ran longer than intended.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
    subscriber_email_addresses = [var.budget_email]
  }

  # 100% forecast: the cluster has been up long enough that AWS projects a
  # full-month overrun. This is the one that catches a cluster left running -
  # it fires days before the actual-spend alarm would.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
    subscriber_email_addresses = [var.budget_email]
  }
}
