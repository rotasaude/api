module Regulation
  # Catálogos fechados do envio da regulação à RNDS (módulo 26c, Valor 4).
  module RndsCatalog
    MIRA_STATUSES = %w[pending booked attended cancelled absence excluded returned-to-requester].freeze
    SYNC_STATUSES = %w[idle queued sending blocked rejected failed excluded erased].freeze
    # Mais `skeleton:<caminho>` (caminho do campo do esqueleto ainda não confirmado).
    # Q23: `missing_priority` (Q15: sem `color` nem `suggested_color`, sem
    # caráter) e `external_absence_without_schedule` (Q22: a falta do pedido
    # externo, sem data nem prestador no 26a), nesta ordem, no fim.
    BLOCK_REASONS = %w[
      missing_diagnosis requester_unit_without_cnes performer_without_cnes
      patient_without_cpf_or_cns performer_cbo_missing specialty_without_sigtap
      missing_priority external_absence_without_schedule
    ].freeze
    DELIVERY_KINDS = %w[create replace delete].freeze
    PRIORITIES = %w[routine urgent].freeze
    DEFAULT_PRIORITY_BY_COLOR = {
      "red" => "urgent", "yellow" => "routine", "green" => "routine", "blue" => "routine"
    }.freeze
    DOMAIN_EVENTS = %w[
      regulation_rnds.queued regulation_rnds.accepted regulation_rnds.blocked
      regulation_rnds.rejected regulation_rnds.excluded regulation_rnds.settings_changed
    ].freeze
    # situação MIRA => [Appointment.status, ServiceRequest.status] (a figura do IG).
    STATUS_RELATION = {
      "pending" => %w[proposed active],
      "booked" => %w[booked active],
      "attended" => %w[fulfilled completed],
      "cancelled" => %w[cancelled revoked],
      "absence" => %w[noshow completed],
      "excluded" => %w[cancelled revoked],
      "returned-to-requester" => %w[waitlist on-hold]
    }.freeze
  end
end
