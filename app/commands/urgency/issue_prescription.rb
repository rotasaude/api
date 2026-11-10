# Prescrição interna do médico da UPA, emitida e alterada em versões (ADR 0050;
# contrato §5 e §12 P1, Q4, Q6; plano, Desvios 3, 4 e 9).
#
# Quem: só o médico (Access.physician_link: 225* com vínculo ativo na UPA do
# atendimento); os demais → Access.refusal (missing_role | missing_link |
# cbo_not_allowed).
#
# Corpo (`items`, 1..20), as recusas de forma todas de uma vez em `problems`
# com o path `items.<n>.<campo>` (a 1ª vai para o topo): chave desconhecida no
# item ou em `frequency`; catalog_item_id fora de `catalog` (o prescritível,
# lido FORA da transação pelo chamador) → catalog_item_invalid; `dose` String
# decimal em Catalog::DOSE e maior que zero (número JSON recusado, Q6);
# `dose_unit` em DOSE_UNITS; `route` em PrescriptionItem::ROUTES;
# `frequency.kind` em FREQUENCY_KINDS, com `interval_hours` só e sempre em
# `interval` e `max_per_day` só e sempre em `if_needed`; `first_dose_at` (padrão
# agora, truncado ao minuto) de agora − 1 h a agora + 24 h; `instructions` até
# 500; `stock_quantity_per_dose` String pelo Pharmacy::Quantity (padrão "1").
# P1: qualquer lista da Portaria 344 vale (a regra do 19d não se aplica); o
# item copia `controlled_list` e grava `stock_unit` = unidade de dispensação.
#
# Estado (atendimento FOR SHARE → encontro FOR NO KEY UPDATE → prescrição
# ativa FOR UPDATE): encontro ou atendimento fechado → 409 encounter_closed;
# sem a consulta de urgência → 422 consultation_required. A `active` anterior
# vira `superseded` ANTES de nascer a nova (índice único parcial, não
# adiável); a nova leva version + 1 e `supersedes`. Evento
# urgency.prescription_issued, só com ids.
module Urgency
  module IssuePrescription
    ITEM_KEYS = %w[catalog_item_id dose dose_unit route frequency first_dose_at instructions stock_quantity_per_dose].freeze
    FREQUENCY_KEYS = %w[kind interval_hours max_per_day].freeze
    KEY_PATH_MAX = 64
    EVENT = "urgency.prescription_issued".freeze

    module_function

    # -> Result.ok(prescription:) | fail(:missing_role | :missing_link | :cbo_not_allowed | :encounter_closed |
    #    :consultation_required) | fail(:invalid_request | :catalog_item_invalid, details: { path:, problems: })
    def call(encounter:, items:, catalog:, by:, now: Time.current)
      unit_id = encounter.attendance.health_unit_id
      link = Access.physician_link(by, unit_id)
      return Result.fail(Access.refusal(by, unit_id)) unless link

      parsed = parse(items, catalog, now)
      return parsed if parsed.failure?

      ApplicationRecord.transaction(requires_new: true) { persist(encounter, parsed.payload, link, by, now) }
    end

    def persist(encounter, rows, link, by, now)
      attendance = Attendance.lock("FOR SHARE").find(encounter.attendance_id)
      locked = UrgencyEncounter.lock("FOR NO KEY UPDATE").find(encounter.id)
      return Result.fail(:encounter_closed) if locked.closed? || attendance.status == "closed"
      return Result.fail(:consultation_required) if locked.consultation_id.nil?

      current = UrgencyPrescription.lock.find_by(urgency_encounter_id: locked.id, status: "active")
      current&.update!(status: "superseded", status_changed_at: now, status_changed_by_user: by)
      # A nova aponta a versão anterior, mesmo suspensa ou encerrada (v1 = sem anterior).
      previous = UrgencyPrescription.where(urgency_encounter_id: locked.id).order(:version).last
      prescription = UrgencyPrescription.create!(urgency_encounter: locked, version: (previous&.version || 0) + 1, supersedes: previous, status: "active",
                                                 prescribed_at: now, prescribed_by_user: by, professional_link: link, cbo_code: link.cbo_code)
      rows.each_with_index { |row, index| prescription.items.create!(row.merge(position: index + 1)) }
      DomainEvents.publish(EVENT, encounter_id: locked.id, prescription_id: prescription.id)
      Result.ok(prescription: prescription)
    end

    def parse(items, catalog, now)
      return refuse([ problem("items") ]) unless items.is_a?(Array) && Catalog::PRESCRIPTION_ITEMS.cover?(items.size)

      problems = []
      rows = items.each_with_index.map { |raw, index| parse_item(raw, index, catalog, now, problems) }
      return refuse(problems) if problems.any?

      Result.ok(rows)
    end

    def parse_item(raw, index, catalog, now, problems)
      base = "items.#{index}"
      unless raw.is_a?(Hash)
        problems << problem(base)
        return nil
      end

      raw = raw.stringify_keys
      add = ->(field, error = :invalid_request) { problems << problem("#{base}.#{field}", error) }
      (raw.keys - ITEM_KEYS).each { |key| add.(key.to_s[0, KEY_PATH_MAX]) }

      found = catalog_item(raw["catalog_item_id"], catalog)
      add.("catalog_item_id", Input.uuid?(raw["catalog_item_id"]) ? :catalog_item_invalid : :invalid_request) unless found
      dose = dose(raw["dose"])
      add.("dose") unless dose
      add.("dose_unit") unless Catalog::DOSE_UNITS.include?(raw["dose_unit"])
      add.("route") unless PrescriptionItem::ROUTES.include?(raw["route"])
      frequency = parse_frequency(raw["frequency"], base, problems)
      first_dose_at = first_dose_at(raw["first_dose_at"], now)
      add.("first_dose_at") unless first_dose_at
      instructions = raw["instructions"]
      add.("instructions") unless instructions.nil? || (instructions.is_a?(String) && instructions.length <= Catalog::INSTRUCTIONS_MAX)
      quantity = Pharmacy::Quantity.parse(raw.fetch("stock_quantity_per_dose", "1"))
      add.("stock_quantity_per_dose") unless quantity

      { catalog_item_id: found&.id, catmat_code: found&.catmat_code, controlled_list: found&.controlled_list.presence,
        stock_unit: found && Pharmacy::DispensingUnit.for(found), dose: dose, dose_unit: raw["dose_unit"], route: raw["route"],
        first_dose_at: first_dose_at, instructions: instructions.presence, stock_quantity_per_dose: quantity }.merge(frequency || {})
    end

    # -> { frequency_kind:, interval_hours:, max_per_day: } | nil (problems já anotados)
    def parse_frequency(raw, base, problems)
      add = ->(field) { problems << problem("#{base}.frequency.#{field}") }
      return add.("kind").then { nil } unless raw.is_a?(Hash)

      raw = raw.stringify_keys
      (raw.keys - FREQUENCY_KEYS).each { |key| add.(key.to_s[0, KEY_PATH_MAX]) }
      kind = raw["kind"]
      return add.("kind").then { nil } unless Catalog::FREQUENCY_KINDS.include?(kind)

      check = lambda do |field, range, wanted|
        value = raw[field]
        ok = wanted ? (value.is_a?(Integer) && range.cover?(value)) : value.nil?
        add.(field) unless ok
        wanted && ok ? value : nil
      end
      { frequency_kind: kind, interval_hours: check.("interval_hours", Catalog::INTERVAL_HOURS, kind == "interval"),
        max_per_day: check.("max_per_day", Catalog::MAX_PER_DAY, kind == "if_needed") }
    end

    def catalog_item(id, catalog) = Input.uuid?(id) ? catalog[id.downcase] : nil

    # String decimal em DOSE e maior que zero; número JSON (e String vazia) recusado.
    def dose(raw)
      return nil unless raw.is_a?(String) && raw.match?(Catalog::DOSE)

      value = BigDecimal(raw)
      value.positive? ? value : nil
    end

    # Padrão agora; aceita de agora − 1 h a agora + 24 h (conferido no valor
    # dado) e grava truncado ao minuto.
    def first_dose_at(raw, now)
      return now.change(sec: 0) if raw.nil?

      time = Input.time(raw)
      time && Catalog::FIRST_DOSE_WINDOW.cover?(time - now) ? time.change(sec: 0) : nil
    end

    def problem(path, error = :invalid_request) = { path: path, error: error.to_s }

    def refuse(problems)
      Result.fail(problems.first[:error].to_sym, details: { path: problems.first[:path], problems: problems })
    end

    private_class_method :persist, :parse, :parse_item, :parse_frequency, :catalog_item, :dose, :first_dose_at, :problem, :refuse
  end
end
