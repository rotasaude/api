# Produção da urgência no BPA (ADR 0050; contrato §9 e §14 Q12, Q25; plano,
# Task 13): o encontro FECHADO da UPA vira até duas linhas, source urgency:
# - a classificação de risco (Urgency::Config.sigtap["classification_code"]),
#   quando houve classificação: quem fez a 1ª e o CBO gravado nela, no dia
#   LOCAL dela;
# - o atendimento médico (care_code), quando há a consulta de urgência
#   finalizada: o autor e o CBO da consulta, no dia LOCAL da finalização, com
#   o 1º CID-10 avaliado nela (por created_at, id) ou nulo.
# Estabelecimento = a UPA (Billing::Establishment.for_unit); quantidade 1,
# caráter urgente, recorded_by nil. O instrumento e a validade do CBO vêm da
# SIGTAP (Billing::Critic). Os códigos são gate (sigtap.yml com review: true).
#
# Nada: encontro ainda aberto; desfecho NON_CARE_OUTCOMES (registered_in_error,
# Q25); evasão antes da classificação (sem classificação nem consulta).
# Paciente provisório não identificado (ou um alias já fundido, lido de novo
# do atendimento): nada, e `pending: :patient` — a competência mostra a
# pendência sem linha (Urgency::BillingPending). A identificação
# (urgency.patient_identified) chama de novo e grava no paciente real.
#
# Idempotente pelos códigos já gravados do encontro (e o índice único
# idx_performed_procedures_urgency). Trava o atendimento FOR NO KEY UPDATE
# antes de ler (a ordem do Urgency::RecordOutcome e do Urgency::Identify:
# atendimento primeiro): serializa dois consumidores do mesmo encontro e a
# fusão, sem bloquear o FOR KEY SHARE dos INSERTs com FK para ele. Depois, a
# competência (FOR SHARE, Billing::Periods dentro do Record.insert!).
#
# Erro do banco no INSERT → InsertFailed só com o id do encontro, sem a causa
# (o DETAIL do Postgres traz a linha, com CID e paciente).
module Billing
  module FromUrgency
    class InsertFailed < StandardError; end

    QUANTITY = 1
    CHARACTER = "urgent".freeze

    module_function

    # -> { created: Integer, pending: :patient | nil }
    def call(encounter)
      ApplicationRecord.transaction(requires_new: true) do
        attendance = Attendance.lock("FOR NO KEY UPDATE").find(encounter.attendance_id)
        current = UrgencyEncounter.includes(:outcome).find(encounter.id)
        next result(0) unless billed?(current)

        owed = lines(current, attendance)
        next result(0) if owed.empty? # evasão antes da classificação: nada devido, nem pendência

        patient = Patient.find(attendance.patient_id)
        next result(0, :patient) if patient.unidentified || patient.merged?

        done = PerformedProcedure.where(urgency_encounter_id: current.id).pluck(:sigtap_code).to_set
        establishment = Establishment.for_unit(attendance.health_unit)
        created = owed.count do |line|
          next false if done.include?(line[:sigtap_code])

          insert!(current, attendance, patient, establishment, line)
          true
        end
        result(created)
      end
    end

    def billed?(encounter)
      encounter.closed? && encounter.outcome && !Urgency::Catalog::NON_CARE_OUTCOMES.include?(encounter.outcome.kind)
    end

    # As linhas devidas do encontro: [{ sigtap_code:, professional:, cbo_code:, performed_on:, cid10:, consultation: }]
    def lines(encounter, attendance)
      codes = Urgency::Config.sigtap
      list = []
      if (first = encounter.classifications.first)
        list << { sigtap_code: codes["classification_code"], professional: first.classified_by_user, cbo_code: first.cbo_code,
                  performed_on: first.created_at.in_time_zone.to_date, cid10: nil, consultation: nil }
      end
      if (consultation = care_consultation(attendance))
        list << { sigtap_code: codes["care_code"], professional: consultation.author_user, cbo_code: consultation.cbo_code,
                  performed_on: consultation.finalized_at.in_time_zone.to_date, cid10: first_cid10(consultation),
                  consultation: consultation }
      end
      list
    end

    def care_consultation(attendance)
      Consultation.where(attendance_id: attendance.id, kind: "urgency", status: "finalized").order(:finalized_at, :id).first
    end

    def first_cid10(consultation)
      code = ConsultationProblem.where(consultation_id: consultation.id, terminology: "cid10").order(:created_at, :id).pick(:code)
      cid = ClinicalTerms.cid10_code(code)
      cid == :invalid ? nil : cid
    end

    def insert!(encounter, attendance, patient, establishment, line)
      Record.insert!(patient: patient, establishment: establishment, professional: line[:professional], cbo_code: line[:cbo_code],
                     source: "urgency", performed_on: line[:performed_on], sigtap_code: line[:sigtap_code], quantity: QUANTITY,
                     cid10: line[:cid10], character: CHARACTER, recorded_by: nil, attendance: attendance,
                     consultation: line[:consultation], urgency_encounter: encounter)
    rescue ActiveRecord::StatementInvalid => e
      # `cause: nil`: o erro do PG (com a linha recusada) não vai junto para o log do job.
      raise InsertFailed, "urgency_encounter_id=#{encounter.id} #{e.class.name}", cause: nil
    end

    def result(created, pending = nil) = { created: created, pending: pending }

    private_class_method :billed?, :lines, :care_consultation, :first_cid10, :insert!, :result
  end
end
