# AWS Budgets: 이번 달 비용이 기준을 넘으면 이메일로 알린다.
#
# 알림만 한다. 예산은 지출을 멈추지 않는다(Budget Actions로 IAM 정책 적용이나 EC2 중지 같은 자동 조치를 붙일 수는 있지만 이 스택은 붙이지 않았다).
# 계정이 Free 플랜이면 크레딧을 넘는 사용은 애초에 막히므로 그것이 예산과 별개의 상한이 된다. Free 플랜이 아니라면 이 알림이 사실상 유일한 경고다.
#
# 알림은 실시간이 아니다. 예산은 청구 데이터로 계산하는데 그 데이터는 하루에 최대 3번 갱신된다(AWS 안내). 돈이 나간 뒤 몇 시간 늦게 올 수 있다.
# 예산은 리전이 없는 전역 서비스라서 provider의 region과 무관하게 만들어진다.
#
# 알림 종류(notification_type)
#   ACTUAL     이미 쓴 금액이 기준을 넘었을 때
#   FORECASTED 지금까지의 사용 추세로 예측한 이번 달 말 금액이 기준을 넘을 것 같을 때. 넘기 전에 오는 경고다.
#              다만 예측에 쓸 사용 이력이 부족한 새 계정에서는 울리지 않을 수 있다.

# 본 예산: 기본 한도 20달러. 50%와 100%에서 실제 사용액을, 100%에서 예측 금액을 알린다.
resource "aws_budgets_budget" "monthly" {
  # 이름에 금액을 넣지 않는다. name을 바꾸면 예산을 지우고 새로 만들게 되는데, 한도(변수)를 바꿀 때마다 그러지 않게 하려는 것이다.
  name        = "dev-ops-study-monthly"
  budget_type = "COST"
  time_unit   = "MONTHLY"

  # limit_amount는 문자열 인자라서 숫자 변수를 문자열로 바꿔 넣는다.
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"

  # 크레딧을 "포함"하면(provider 기본값은 true) 크레딧이 깎아 준 만큼이 비용에서 빠진다. 그러면 크레딧이 남아 있는 동안에는
  # 실제로 쓴 금액이 커져도 예산에 잡히는 금액이 0 근처에 머물러서 알림이 울리지 않는다. 이 예산은 "크레딧이 덮어 주더라도
  # 얼마나 쓰고 있는지"를 알리려는 것이라 크레딧을 빼고(false) 센다. 나머지 항목은 기본값을 그대로 쓴다.
  cost_types {
    include_credit = false
  }

  # 실제 사용액이 한도의 50%를 넘었을 때
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # 실제 사용액이 한도(100%)를 넘었을 때
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # 이번 달 말까지의 예측 금액이 한도(100%)를 넘을 것 같을 때. 위의 ACTUAL 100%보다 먼저 올 수 있다.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# 조기 경보: 본 예산에 닿기 훨씬 전에, 이번 달 사용액이 작은 기준(기본 5달러)을 넘자마자 알린다. "돈이 나가기 시작했다"를 일찍 알아채려는 것이다.
resource "aws_budgets_budget" "early_warning" {
  name        = "dev-ops-study-early-warning"
  budget_type = "COST"
  time_unit   = "MONTHLY"

  limit_amount = tostring(var.early_warning_limit_usd)
  limit_unit   = "USD"

  # 본 예산과 같은 이유로 크레딧을 뺀 금액으로 센다. 조기 경보가 크레딧에 가려지면 의미가 없다.
  cost_types {
    include_credit = false
  }

  # 실제 사용액이 이 예산의 한도(100%)를 넘었을 때
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}
