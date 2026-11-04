# Produção do CAPS no BPA (ADR 0049; contrato §8, §15 P2 e P3; plano, Desvio
# 11): só a ação bpa_c ou bpa_i vira linha, uma por ação (consulta + índice
# único em psychosocial_action_id); a raas_psi vai na RAAS do mês, nunca aqui.
# - BPA-C: sem paciente e sem CID, com a quantidade da ação (nunca uma linha
#   por participante);
# - BPA-I: o paciente do único participante com paciente (a crítica da ação já
#   exige exatamente um) e o CID principal da matrícula dele, quando houver.
# Estabelecimento = o CAPS (Billing::Establishment.for_unit); profissional e
# CBO os gravados na ação; data = o dia LOCAL da ação; caráter eletivo;
# recorded_by nil. A crítica é a do 22 (Billing::Critic), com a BPA-C sem
# paciente.
#
# Travas (ruling do ledger: CAPS → competência → registros): a linha do CAPS
# FOR NO KEY UPDATE antes de tudo (não bloqueia o FOR KEY SHARE dos INSERTs
# com FK para o CAPS) — serializa com o Psychosocial::CancelAction, que a
# trava FOR SHARE e só então procura a linha (a ação cancelada nunca ganha
# linha; a linha nunca nasce depois da busca do cancelamento) — e então a
# competência (FOR SHARE, Billing::Periods dentro do Record.insert!).
#
# Erro do banco no INSERT → InsertFailed só com o id da ação, sem a causa (o
# DETAIL do Postgres traz a linha, com CID e paciente).
module Billing
  module FromPsychosocial
    class InsertFailed < StandardError; end

    BILLED = %w[bpa_c bpa_i].freeze

    module_function

    # -> PerformedProcedure | nil (raas_psi, ação cancelada ou já levada)
    def call(action)
      return nil unless BILLED.include?(action.instrument)

      ApplicationRecord.transaction(requires_new: true) do
        unit = HealthUnit.lock("FOR NO KEY UPDATE").find(action.health_unit_id)
        current = PsychosocialAction.find(action.id)
        next nil if current.cancelled? || PerformedProcedure.exists?(psychosocial_action_id: current.id)

        insert!(current, unit)
      end
    end

    def insert!(action, unit)
      patient, cid = action.instrument == "bpa_i" ? individual(action) : [ nil, nil ]
      Record.insert!(patient: patient, establishment: Establishment.for_unit(unit), professional: action.professional_user,
                     cbo_code: action.cbo_code, source: "psychosocial", performed_on: action.performed_at.in_time_zone.to_date,
                     sigtap_code: action.sigtap_code, quantity: action.quantity, cid10: cid, character: "elective", recorded_by: nil,
                     psychosocial_action: action)
    rescue ActiveRecord::StatementInvalid => e
      # `cause: nil`: o erro do PG (com a linha recusada) não vai junto para o log do job.
      raise InsertFailed, "psychosocial_action_id=#{action.id} #{e.class.name}", cause: nil
    end

    # [paciente, CID principal da matrícula | nil] do participante com paciente.
    def individual(action)
      participant = action.psychosocial_action_participants.where.not(patient_id: nil).includes(:patient, :psychosocial_enrollment).first
      return [ nil, nil ] unless participant

      code = ClinicalTerms.normalize(participant.psychosocial_enrollment&.cid_main)
      [ participant.patient, code.match?(ClinicalTerms::CID10_CODE) ? code : nil ]
    end

    private_class_method :insert!, :individual
  end
end
