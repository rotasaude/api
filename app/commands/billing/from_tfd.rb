# Produção do TFD (ADR 0048; contrato §6; §14 T11, T26): uma linha BPA por
# ajuda de custo (tfd_allowances), source tfd, com o paciente do processo
# (também na linha do acompanhante), o médico do laudo com o CBO gravado no
# processo (requester_cbo), a unidade de faturamento do TFD
# (transport_settings.tfd_billing_health_unit_id) como estabelecimento, a
# data do trecho, o código e a quantidade da ajuda, o CID do laudo e caráter
# eletivo; tfd_leg_id só de rastro. Sem a unidade configurada (o authorize
# já exige), nada. A crítica é a de sempre (Billing::Critic não muda).
# Idempotente por ajuda (consulta + índice único em tfd_allowance_id).
module Billing
  module FromTfd
    module_function

    # allowances: relação/lista de TfdAllowance -> Integer (linhas criadas)
    def call(allowances)
      list = allowances.to_a
      return 0 if list.empty?

      unit = HealthUnit.find_by(id: Transport::Settings.current.tfd_billing_health_unit_id)
      unless unit
        Rails.logger.warn("[Billing::FromTfd] tfd_billing_health_unit_missing tfd_allowance_ids=#{list.map(&:id).join(',')}")
        return 0
      end

      establishment = Establishment.for_unit(unit)
      done = PerformedProcedure.where(tfd_allowance_id: list.map(&:id)).pluck(:tfd_allowance_id).to_set
      cases = TfdCase.where(id: list.map(&:tfd_case_id).uniq).includes(:patient, :requester_user).index_by(&:id)
      legs = TfdLeg.where(id: list.map(&:tfd_leg_id).uniq).index_by(&:id)
      list.sort_by { |allowance| [ allowance.created_at, allowance.id ] }.count do |allowance|
        next false if done.include?(allowance.id)

        tfd_case = cases.fetch(allowance.tfd_case_id)
        leg = legs.fetch(allowance.tfd_leg_id)
        cid = ClinicalTerms.cid10_code(tfd_case.report&.dig("cid10"))
        Record.insert!(patient: tfd_case.patient, establishment: establishment, professional: tfd_case.requester_user,
                       cbo_code: tfd_case.requester_cbo, source: "tfd", performed_on: leg.date, sigtap_code: allowance.sigtap_code,
                       quantity: allowance.quantity, cid10: cid == :invalid ? nil : cid, character: "elective", recorded_by: nil,
                       tfd_allowance: allowance, tfd_leg: leg)
        true
      end
    end
  end
end
