# -----------------------------------------------------------------------------
# Resource Monitor — cost control for Payment Authorization Command Center
# Spec reference: Section 3.9.6
#
# Monitors credit usage across all payment warehouses and triggers
# notifications/suspensions at defined thresholds.
#
# Note: Assigning resource monitors to warehouses requires ACCOUNTADMIN role.
# -----------------------------------------------------------------------------

resource "snowflake_resource_monitor" "payments_monitor" {
  name         = "PAYMENTS_MONITOR"
  credit_quota = 100

  frequency       = "MONTHLY"
  start_timestamp = "IMMEDIATELY"

  notify_triggers            = [75, 90]
  suspend_trigger            = 100
  suspend_immediate_trigger  = 110
}
