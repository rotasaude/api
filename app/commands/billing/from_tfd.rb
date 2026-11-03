# Produção do TFD (ADR 0048; contrato §6; §14 T11, T26): uma linha BPA por
# ajuda de custo (tfd_allowances), source tfd, com o paciente do processo
# (também na linha do acompanhante), o médico do laudo com o CBO gravado no
# processo (requester_cbo), a unidade de faturamento do TFD
# (transport_settings.tfd_billing_health_unit_id) como estabelecimento, a
# data do trecho, o código e a quantidade da ajuda, o CID do laudo e caráter
# eletivo; tfd_leg_id só de rastro. A crítica é a de sempre (Billing::Critic
# não muda). Idempotente por ajuda (consulta + índice único em
# tfd_allowance_id).
#
# Falhas (Task 13 I1/I2), sempre só com ids:
# - sem a unidade configurada → BillingUnitMissing: o consumidor falha, o
#   evento fica pendente e a nova tentativa (limitada, Billing::TfdProductionJob)
#   grava depois de configurada;
# - quantidade fora de PerformedProcedure::QUANTITY → a ajuda é pulada e as
#   outras seguem (o AddLeg já recusa a volta além de 999 noites); a pulada
#   volta só no retorno (`skipped`, ids) — sem log no código do faturamento
#   (invariante do módulo 22, FW15) — e fica visível como ajuda sem linha BPA;
# - erro do banco no INSERT → InsertFailed sem a causa (o DETAIL do Postgres
#   traz a linha, com CID e paciente).
module Billing
  module FromTfd
    class BillingUnitMissing < StandardError; end
    class InsertFailed < StandardError; end

    module_function

    # allowances: relação/lista de TfdAllowance -> { created: Integer, skipped: [ids das ajudas puladas] }
    def call(allowances)
      list = allowances.to_a
      skipped = []
      return { created: 0, skipped: skipped } if list.empty?

      unit = HealthUnit.find_by(id: Transport::Settings.current.tfd_billing_health_unit_id)
      raise BillingUnitMissing, "tfd_billing_health_unit_missing tfd_allowance_ids=#{list.map(&:id).join(',')}" unless unit

      establishment = Establishment.for_unit(unit)
      done = PerformedProcedure.where(tfd_allowance_id: list.map(&:id)).pluck(:tfd_allowance_id).to_set
      cases = TfdCase.where(id: list.map(&:tfd_case_id).uniq).includes(:patient, :requester_user).index_by(&:id)
      legs = TfdLeg.where(id: list.map(&:tfd_leg_id).uniq).index_by(&:id)
      created = list.sort_by { |allowance| [ allowance.created_at, allowance.id ] }.count do |allowance|
        next false if done.include?(allowance.id)

        unless PerformedProcedure::QUANTITY.cover?(allowance.quantity)
          skipped << allowance.id
          next false
        end

        insert!(allowance, cases.fetch(allowance.tfd_case_id), legs.fetch(allowance.tfd_leg_id), establishment)
        true
      end
      { created: created, skipped: skipped }
    end

    def insert!(allowance, tfd_case, leg, establishment)
      cid = ClinicalTerms.cid10_code(tfd_case.report&.dig("cid10"))
      Record.insert!(patient: tfd_case.patient, establishment: establishment, professional: tfd_case.requester_user,
                     cbo_code: tfd_case.requester_cbo, source: "tfd", performed_on: leg.date, sigtap_code: allowance.sigtap_code,
                     quantity: allowance.quantity, cid10: cid == :invalid ? nil : cid, character: "elective", recorded_by: nil,
                     tfd_allowance: allowance, tfd_leg: leg)
    rescue ActiveRecord::StatementInvalid => e
      # `cause: nil`: o erro do PG (com a linha recusada) não vai junto para o log do job.
      raise InsertFailed, "tfd_allowance_id=#{allowance.id} #{e.class.name}", cause: nil
    end

    private_class_method :insert!
  end
end
