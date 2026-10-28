# Constantes do catálogo de alvos reguláveis do módulo 26a (ADR 0044). As
# listas de especialidades e de procedimentos ficam em config/regulation/*.yml.
module CareRegulation
  module Catalog
    TYPES = %w[specialty procedure].freeze
    COLORS = %w[red yellow green blue].freeze
    COLOR_RANK = { "red" => 0, "yellow" => 1, "green" => 2, "blue" => 3 }.freeze
    DEFAULT_DEADLINE_DAYS = { "red" => 7, "yellow" => 30, "green" => 90, "blue" => 180 }.freeze
    DEADLINE_DAYS = (1..365)
    STATUSES = %w[draft pending returned authorized scheduled completed missed denied cancelled closed external].freeze
    WAITING_STATUSES = %w[pending returned authorized external].freeze
    QUEUE_STATUSES = (STATUSES - %w[draft missed]).freeze
    TERMINAL_STATUSES = %w[completed denied cancelled closed].freeze
    PROVIDER_KINDS = %w[own contracted consortium ppi].freeze
    EXTERNAL_SYSTEMS = %w[sisreg care cross other].freeze
    RELEASE_REASONS = %w[cancelled citizen_cancelled unit_dismissed consent_revoked].freeze
    PHYSICIAN_PREFIX = "225".freeze
    NURSE_PREFIX = "2235".freeze
    DENTIST_PREFIX = "2232".freeze
    JUSTIFICATION = (10..2000)
    REASON = (10..500)
    PLACE_MAX = 200
    NOTES_MAX = 500
    NAME_MAX = 120
    PROVIDER_NAME = (3..120)
    QUANTITY = (0..9999)
    MAX_MISSES = 2
    MAX_PER_CONSULTATION = 10
    EXTERNAL_NUMBER = %r{\A[0-9A-Za-z./-]{1,30}\z}
    CNES = /\A[0-9]{7}\z/
    SPECIALTY_CODE = /\A[0-9]{6}\z/
    PROCEDURE_CODE = /\A[0-9]{10}\z/
    MONTH = /\A[0-9]{4}-(0[1-9]|1[0-2])\z/
    TRAIL_ACCESS = "regulation".freeze
    SYNC_NOTES = {
      missed: "Falta no horário regulado: o pedido voltou à regulação",
      cancelled: "Pedido de regulação cancelado pela regulação"
    }.freeze
    CITIZEN_STATUS = {
      "pending" => "waiting", "returned" => "returned", "authorized" => "waiting", "external" => "waiting",
      "scheduled" => "scheduled", "completed" => "completed", "denied" => "denied",
      "cancelled" => "closed", "closed" => "closed"
    }.freeze

    # "AAAA-MM" -> primeiro dia do mês (Date); nil para texto fora do formato.
    def self.parse_month(value)
      return nil unless value.is_a?(String) && value.match?(MONTH)

      Date.new(value[0, 4].to_i, value[5, 2].to_i, 1)
    end
  end
end
