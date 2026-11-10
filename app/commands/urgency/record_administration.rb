# Checagem da medicação na UPA (ADR 0050; contrato §6 e §12 Q5, Q6; plano,
# Desvios 6, 7, 8 e 10): imutável (trigger), uma por horário.
#
# `attrs` (o corpo, chaves String): prescription_item_id, scheduled_at?,
# status, reason?, administered_at?, stock_lot_id?, stock_quantity?.
# `stock`: Urgency::StockGate.usable? lido pelo chamador FORA da transação
# ("desligado" = desligado ou não utilizável, Q6).
#
# id ausente ou malformado → 422 `prescription_item_id`; item inexistente →
# 404. Sob as travas (atendimento FOR SHARE → encontro FOR SHARE → prescrição
# FOR SHARE → todos os itens do mesmo medicamento na prescrição FOR NO KEY
# UPDATE, em ordem de id, que serializa as checagens do medicamento para a dose
# em dobro e o `max_per_day`; as outras versões já se serializam pela trava do
# encontro contra a emissão e a suspensão), na ordem do Desvio 6:
# 1. encontro ou atendimento fechado → 409 encounter_closed;
# 2. acesso: Access.nursing_or_physician_link (2235*, 3222*, 225*) na UPA do
#    atendimento, senão Access.refusal (403);
# 3. versão do item que não está `active` → 422 prescription_not_active;
# 4. forma (todas de uma vez em `problems`): `status` na lista; `reason`
#    (10..500, aparado) só e sempre fora de `administered`; `administered_at`
#    só em `administered` (padrão agora; até agora + 5 min; nunca antes do
#    `prescribed_at` da versão, A15); `scheduled_at` obrigatório em
#    `once`/`interval` e proibido em `if_needed`; `stock_lot_id`/`stock_quantity`
#    fora de `administered` → invalid_request, e em `administered` com `stock`
#    falso → stock_deduction_disabled (Desvio 8);
# 5. horário: fora do aprazamento (Schedule.slot?) → 422 slot_invalid; mais de
#    60 min adiantado → 422 slot_not_due (Q5; o passado vale com o encontro
#    aberto); o mesmo `catalog_item_id` no mesmo horário em qualquer versão →
#    409 slot_taken (e o índice idx_urgency_administrations_slot como rede);
#    `if_needed` + `administered` com `max_per_day` administradas nas 24 h
#    antes do `administered_at` → 422 max_per_day_reached (A16).
# Grava com `recorded_at: now`, o vínculo e o CBO dele; evento
# urgency.medication_checked só com ids. O motivo nunca em evento nem log.
module Urgency
  module RecordAdministration
    EVENT = "urgency.medication_checked".freeze
    STOCK_KEYS = %w[stock_lot_id stock_quantity].freeze
    SLOT_INDEX = "idx_urgency_administrations_slot".freeze

    module_function

    # -> Result.ok(administration:, shortfall: nil) | fail(:not_found | :encounter_closed | :missing_role |
    #    :missing_link | :cbo_not_allowed | :prescription_not_active | :slot_taken | :max_per_day_reached) |
    #    fail(:invalid_request | :stock_deduction_disabled | :slot_invalid | :slot_not_due, details: { path:, problems: })
    def call(attrs:, by:, stock:, now: Time.current)
      id = attrs["prescription_item_id"]
      return refuse([ problem("prescription_item_id") ]) unless Input.uuid?(id)

      item = UrgencyPrescriptionItem.includes(urgency_prescription: :urgency_encounter).find_by(id: id.downcase)
      return Result.fail(:not_found) unless item

      ApplicationRecord.transaction(requires_new: true) { record(item, attrs, by, stock, now) }
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(SLOT_INDEX)

      Result.fail(:slot_taken)
    end

    def record(item, attrs, by, stock, now)
      encounter = item.urgency_prescription.urgency_encounter
      attendance = Attendance.lock("FOR SHARE").find(encounter.attendance_id)
      locked = UrgencyEncounter.lock("FOR SHARE").find(encounter.id)
      return Result.fail(:encounter_closed) if locked.closed? || attendance.status == "closed"

      link = Access.nursing_or_physician_link(by, attendance.health_unit_id)
      return Result.fail(Access.refusal(by, attendance.health_unit_id)) unless link

      prescription = UrgencyPrescription.lock("FOR SHARE").find(item.urgency_prescription_id)
      return Result.fail(:prescription_not_active) unless prescription.active?

      # A dose em dobro e o max_per_day são por medicamento, e a versão pode
      # trazer o mesmo medicamento em mais de um item: trava todos, em ordem de id.
      UrgencyPrescriptionItem.where(urgency_prescription_id: prescription.id, catalog_item_id: item.catalog_item_id)
                             .order(:id).lock("FOR NO KEY UPDATE").to_a
      parsed = parse(item, prescription, attrs, stock, now)
      return parsed if parsed.failure?

      row = parsed.payload
      refusal = slot_refusal(item, row, locked, now)
      return refusal if refusal

      # Desvio 7 (Task 10): com `stock` e `administered`, o Urgency::DeductStock
      # entra AQUI, antes de gravar — o savepoint { administração com lote e
      # quantidade; Ledger.record! } — e devolve a falta, se houver.
      administration = UrgencyAdministration.create!(
        urgency_prescription_item: item, urgency_encounter: locked, status: row[:status], scheduled_at: row[:scheduled_at],
        administered_at: row[:administered_at], reason: row[:reason], recorded_at: now, recorded_by_user: by,
        professional_link: link, cbo_code: link.cbo_code
      )
      DomainEvents.publish(EVENT, encounter_id: locked.id, administration_id: administration.id)
      Result.ok(administration: administration, shortfall: nil)
    end

    def parse(item, prescription, attrs, stock, now)
      status = attrs["status"]
      # `status` inválido volta sozinho: as outras regras de forma dependem dele.
      return refuse([ problem("status") ]) unless Catalog::ADMINISTRATION_STATUSES.include?(status)

      administered = status == "administered"
      problems = []
      reason = reason(attrs["reason"], administered)
      problems << problem("reason") if reason == :invalid
      administered_at = administered_at(attrs["administered_at"], administered, prescription, now)
      problems << problem("administered_at") if administered_at == :invalid
      scheduled_at = scheduled_at(attrs["scheduled_at"], item)
      problems << problem("scheduled_at") if scheduled_at == :invalid
      STOCK_KEYS.each do |key|
        next if attrs[key].nil?

        if !administered then problems << problem(key)
        elsif !stock then problems << problem(key, :stock_deduction_disabled)
        end
      end
      return refuse(problems) if problems.any?

      Result.ok(status: status, reason: reason, administered_at: administered_at, scheduled_at: scheduled_at)
    end

    # Só e sempre fora de `administered`. -> String | nil | :invalid
    def reason(raw, administered)
      return raw.nil? ? nil : :invalid if administered

      text = raw.is_a?(String) ? raw.strip : nil
      text && Catalog::ADMINISTRATION_REASON.cover?(text.length) ? text : :invalid
    end

    # A15. -> Time | nil | :invalid
    def administered_at(raw, administered, prescription, now)
      return raw.nil? ? nil : :invalid unless administered
      return now if raw.nil?

      time = Input.time(raw)
      ok = time && time <= now + Catalog::ADMINISTERED_AT_TOLERANCE && time >= prescription.prescribed_at
      ok ? time : :invalid
    end

    # -> Time | nil | :invalid
    def scheduled_at(raw, item)
      return raw.nil? ? nil : :invalid if item.frequency_kind == "if_needed"

      Input.time(raw) || :invalid
    end

    # -> Result (a recusa) | nil
    def slot_refusal(item, row, encounter, now)
      at = row[:scheduled_at]
      if at
        return refuse([ problem("scheduled_at", :slot_invalid) ]) unless Schedule.slot?(item, at, now: now)
        return refuse([ problem("scheduled_at", :slot_not_due) ]) if at > now + Catalog::SLOT_DUE_AHEAD
        return Result.fail(:slot_taken) if slot_taken?(item, at, encounter)
      elsif row[:status] == "administered" && Schedule.if_needed_used(item, at: row[:administered_at]) >= item.max_per_day
        return Result.fail(:max_per_day_reached)
      end
      nil
    end

    # Q5: o mesmo medicamento no mesmo horário, em qualquer versão da prescrição do encontro.
    def slot_taken?(item, at, encounter)
      UrgencyAdministration.joins(:urgency_prescription_item)
                           .where(urgency_encounter_id: encounter.id, scheduled_at: at, urgency_prescription_items: { catalog_item_id: item.catalog_item_id })
                           .exists?
    end

    def problem(path, error = :invalid_request) = { path: path, error: error.to_s }

    def refuse(problems)
      Result.fail(problems.first[:error].to_sym, details: { path: problems.first[:path], problems: problems })
    end

    private_class_method :record, :parse, :reason, :administered_at, :scheduled_at, :slot_refusal, :slot_taken?, :problem, :refuse
  end
end
