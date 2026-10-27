# Códigos do módulo 25 (ADR 0043; contrato §1; plano, "Valores fixados" 2).
module Surveillance
  module Catalog
    DEADLINES = { "immediate" => 24.hours, "weekly" => 7.days }.freeze
    ORIGINS = %w[consultation manual safety_net].freeze
    STATUSES = %w[possible notified investigating closed entered dismissed].freeze
    OPEN_STATUSES = %w[possible notified investigating].freeze
    OVERDUE_STATUSES = %w[possible notified].freeze
    CLASSIFICATIONS = %w[confirmed discarded inconclusive].freeze
    TRANSITIONS = { "possible" => %w[notified], "notified" => %w[investigating], "investigating" => %w[closed],
                    "closed" => %w[entered] }.freeze
    DEFAULT_REPEAT_AFTER_DAYS = 30
    NOTIFIER_CBO_PREFIXES = %w[225 2235].freeze
    REASON_MAX = 500
    OFFICIAL_NUMBER = /\A[0-9A-Za-z.\/-]{1,30}\z/
    PLATFORM_CODE = /\A(?!local_)[a-z][a-z0-9_]{1,47}\z/
    LOCAL_CODE = /\Alocal_[a-z0-9_]{1,40}\z/
    CID10 = /\A[A-Z][0-9]{2}[0-9X]?\z/
    CIAP2 = /\A[A-Z][0-9]{2}\z/
    NAME_MAX = 120
    IBGE = /\A[0-9]{7}\z/
    # Raça/cor do paciente (códigos do BPA: 03 parda, 04 amarela) → Sinan (4 parda, 3 amarela); sem raça → "9".
    RACE_TO_SINAN = { "01" => "1", "02" => "2", "03" => "4", "04" => "3", "05" => "5" }.freeze
    # Resto → "I" (ignorado).
    SEX_TO_SINAN = { "male" => "M", "female" => "F" }.freeze
    TRAIL_ACCESS = "surveillance"
  end
end
