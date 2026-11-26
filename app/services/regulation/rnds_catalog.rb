module Regulation
  # Catálogos fechados do envio da regulação à RNDS (módulo 26c, Valor 4).
  module RndsCatalog
    MIRA_STATUSES = %w[pending booked attended cancelled absence excluded returned-to-requester].freeze
    SYNC_STATUSES = %w[idle queued sending blocked rejected failed excluded erased].freeze
    # Mais `skeleton:<caminho>` (caminho do campo do esqueleto ainda não confirmado).
    # `missing_priority` (Q15): sem `color` nem `suggested_color`, o caráter não
    # sai do `priority_by_color` e nada é enviado.
    BLOCK_REASONS = %w[
      missing_diagnosis requester_unit_without_cnes performer_without_cnes
      patient_without_cpf_or_cns performer_cbo_missing specialty_without_sigtap
      missing_priority
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
