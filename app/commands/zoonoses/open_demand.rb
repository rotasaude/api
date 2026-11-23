# Encaminhamento automático da demanda de zoonoses (módulo 35b, ADR 0054;
# contrato §4; decisão 31; Q13–Q15; Review Focus 2). Chamado pelo
# Ombudsman::Register, DENTRO da transação do registro, quando a manifestação
# traz `zoonoses_subtype` (o gate já foi conferido pelo controlador):
#
# 1. Ombudsman::Subjects.ensure_zoonoses! e Ombudsman::Classify com o ator do
#    sistema e o assunto `zoonoses.<subtipo>`: received → in_analysis;
# 2. a UVZ: a unidade environmental_surveillance ativa de menor created_at.
#    Sem ela, ou sem ninguém da equipe do centro (Zoonoses::Access
#    .team_user_ids), para aqui: a manifestação fica in_analysis, já
#    classificada, e segue a triagem do 33 (Q13);
# 3. Ombudsman::Forward com o ator do sistema, `zoonoses: true`, e o extrato
#    = só o texto do cidadão (o subtipo e o place_address ficam em campos
#    próprios: zoonoses_demands.subtype e ombudsman_manifestations
#    .place_address; o limite de 4000 nunca estoura, Q13). O Forward cria a
#    zoonoses_demands `open` (demand!) na mesma transação dele.
#
# Os passos 1 e 3 rodam cada um num savepoint: a recusa do Forward (a UVZ
# desativada entre a leitura e a trava, por exemplo) ou a falha do banco
# depois de o encaminhamento gravado voltam SÓ o encaminhamento, o evento e a
# demanda; o registro do cidadão e a classificação ficam (Review Focus 2). A
# falha da classificação deixa a manifestação `received`, ainda gravada. Nunca há
# demanda sem encaminhamento: os dois nascem e voltam juntos. O log leva só o
# id da manifestação e o motivo, nunca texto nem endereço.
#
# A linha do tempo ordena por (created_at, id) e o registro grava tudo no
# mesmo `now`: a classificação fica 1 µs e o encaminhamento 2 µs depois do
# recebimento (STEP), para os três eventos saírem na ordem em que aconteceram.
module Zoonoses
  module OpenDemand
    STEP = Rational(1, 1_000_000)

    module_function

    # -> Result.ok(manifestation:, forwarding:, demand:) (encaminhada)
    #  | Result.ok(manifestation:, forwarding: nil, demand: nil) (in_analysis classificada)
    #  | Result.fail(...) (a classificação ou o encaminhamento falharam; o registro fica)
    def call(manifestation:, subtype:, now:)
      raise ArgumentError, "Zoonoses::OpenDemand: subtipo fora da lista" unless Catalog::SUBTYPES.include?(subtype)

      classified = savepoint(manifestation) do
        subject = Ombudsman::Subjects.ensure_zoonoses!(now: now)[:children].fetch(subtype)
        Ombudsman::Classify.call(manifestation_id: manifestation.id, expected_state: "received",
                                 attrs: { "subject_id" => subject.id }, by: nil, now: now + STEP)
      end
      return classified if classified.failure?

      unit = HealthUnit.where(active: true, kind: Access::UNIT_KIND).order(:created_at, :id).first
      return Result.ok(manifestation: manifestation, forwarding: nil, demand: nil) if unit.nil? || Access.team_user_ids.empty?

      savepoint(manifestation) do
        Ombudsman::Forward.call(manifestation_id: manifestation.id, expected_state: "in_analysis", department_id: nil,
                                health_unit_id: unit.id, extract: manifestation.body, by: nil, zoonoses: true, now: now + (2 * STEP))
      end
    end

    # A demanda do encaminhamento à UVZ (pelo Ombudsman::Forward, na transação
    # dele): o subtipo do `code` do assunto da manifestação, ou `other`.
    def demand!(forwarding:, manifestation:, now:)
      subtype = Ombudsman::Subjects.subtype_of(manifestation.subject) || "other"
      demand = ZoonosesDemand.create!(ombudsman_forwarding: forwarding, subtype: subtype, state: "open", created_at: now, updated_at: now)
      DomainEvents.publish("zoonoses_demand.opened", zoonoses_demand_id: demand.id)
      demand
    end

    # O bloco (que devolve Result) num savepoint: a recusa volta o savepoint
    # (ActiveRecord::Rollback); a falha do banco também, e vira Result.fail
    # — a transação do registro segue usável e o registro fica.
    def savepoint(manifestation)
      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        result = yield
        raise ActiveRecord::Rollback if result.failure?
      end
      result.failure? ? warn!(manifestation, result) : result
    rescue ActiveRecord::ActiveRecordError => e
      warn!(manifestation, Result.fail(:database_error), error: e.class.name)
    end

    def warn!(manifestation, result, error: nil)
      Rails.logger.warn("[Zoonoses::OpenDemand] not_forwarded manifestation_id=#{manifestation.id} reason=#{result.reason}" \
                        "#{" error=#{error}" if error}")
      result
    end

    private_class_method :savepoint, :warn!
  end
end
