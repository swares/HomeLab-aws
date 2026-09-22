# Backstop for the forgotten-cluster failure mode. The nightly teardown timer
# is the primary control; this is what catches the night it did not run.
#
# Emails you directly - no SNS topic. Until 2026-09-21 alerts also went through
# an SNS topic in tofu/, which was recreated on every `eks-up` and so sent a
# fresh subscription-confirmation email each time; it was never confirmed and
# delivered nothing. Budgets' own email subscribers need no confirmation.

resource "aws_budgets_budget" "monthly" {
  name         = "homelab-aws-monthly"
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
    subscriber_email_addresses = [var.budget_email]
  }

  # 100% forecast: fires days before the actual-spend alarm when a cluster
  # has been left up long enough for AWS to project a full-month overrun.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }

  # 100% actual: the month is already over budget.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}
