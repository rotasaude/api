# Marca diária da ouvidoria (ADR 0051; A13): uma por (dia local, tipo) — o job
# de prazos e o primeiro bloqueio do teto anônimo. Nunca é apagada (trigger).
class OmbudsmanDailyRun < ApplicationRecord
  KINDS = %w[deadlines anonymous_cap].freeze
end
