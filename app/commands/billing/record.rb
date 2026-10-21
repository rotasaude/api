# Gravação do procedimento realizado (ADR 0039; spec §5.1–§5.3; contrato §3).
# Sempre grava: a crítica vai nos campos (Billing::Critic, lida fora da
# transação). A competência do estabelecimento é travada FOR SHARE antes do
# INSERT (Billing::Periods). Data: hoje ou antes, até o 1º dia da
# competência de 3 meses antes (BPA 04.13). Ordem das recusas: código,
# quantidade, data, CID, caráter. `insert!` é o caminho sem validação de
# entrada (laboratório, Billing::FromLab).
module Billing
  module Record
    CODE = /\A\d{10}\z/
    CID = /\A[A-Z]\d{2}[0-9X]?\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    WINDOW_MONTHS = 3

    module_function

    def call(patient:, establishment:, professional:, source:, params:, recorded_by:, cbo_code: nil, attendance: nil, consultation: nil,
             today: Time.zone.today)
      code = params["sigtap_code"]
      return Result.fail(:invalid_sigtap_code) unless code.is_a?(String) && code.match?(CODE)

      quantity = params["quantity"]
      return Result.fail(:invalid_quantity) unless quantity.is_a?(Integer) && quantity.between?(1, 999)

      on = date(params["performed_on"])
      return Result.fail(:invalid_date) unless on && on <= today && on >= (today << WINDOW_MONTHS).beginning_of_month

      cid = cid10(params["cid10"])
      return Result.fail(:invalid_cid10) if cid == :invalid

      character = params["character"].nil? ? "elective" : params["character"]
      return Result.fail(:invalid_character) unless PerformedProcedure::CHARACTERS.include?(character)

      procedure = insert!(patient: patient, establishment: establishment, professional: professional,
                          cbo_code: cbo_code || Staff.cbo_for(professional, establishment), source: source, performed_on: on,
                          sigtap_code: code, quantity: quantity, cid10: cid, character: character, recorded_by: recorded_by,
                          attendance: attendance, consultation: consultation)
      Result.ok(procedure: procedure)
    end

    def insert!(patient:, establishment:, professional:, cbo_code:, source:, performed_on:, sigtap_code:, quantity:, cid10:, character:,
                recorded_by:, attendance: nil, consultation: nil, lab_report_item: nil)
      outcome = Critic.call(Critic::Facts.new(establishment: establishment, sigtap_code: sigtap_code, performed_on: performed_on,
                                              cbo_code: cbo_code, professional_cns: Staff.cns(professional), cid10: cid10, patient: patient))
      ApplicationRecord.transaction(requires_new: true) do
        period, late = Periods.assign!(establishment, performed_on.strftime("%Y%m"))
        procedure = PerformedProcedure.create!(
          **establishment.key, patient: patient, professional_user: professional, cbo_code: cbo_code, performed_on: performed_on,
          sigtap_code: sigtap_code, quantity: quantity, cid10: cid10, character: character, source: source, attendance: attendance,
          consultation: consultation, lab_report_item: lab_report_item, recorded_by_user: recorded_by, instrument: outcome.instrument,
          billable: outcome.billable, blocking_reasons: outcome.reasons, sigtap_competence: outcome.sigtap_competence,
          sigtap_fallback: outcome.fallback, billing_period: period, billing_competence: period&.competence, late: late
        )
        DomainEvents.publish("performed_procedure.recorded", performed_procedure_id: procedure.id, source: source,
                                                              billable: outcome.billable)
        procedure
      end
    end

    def date(value)
      value.is_a?(String) && value.match?(DATE) ? Date.iso8601(value) : nil
    rescue Date::Error
      nil
    end

    # nil (sem CID), o código sem ponto em maiúsculas, ou :invalid (fora do
    # formato, ou fora da CID-10 ativa quando há uma).
    def cid10(value)
      return nil if value.nil? || value == ""
      return :invalid unless value.is_a?(String)

      code = value.delete(".").strip.upcase
      return :invalid unless code.match?(CID)

      release = TerminologyRelease.active.where(kind: "cid10").order(activated_at: :desc).first
      release.nil? || Cid10Code.exists?(release_id: release.id, code: code) ? code : :invalid
    end
    private_class_method :date, :cid10
  end
end
