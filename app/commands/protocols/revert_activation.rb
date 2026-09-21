# Reversão de emergência (spec de assinaturas §6, S10).
#
# Um protocolo com erro em uso prioriza triagens errado enquanto se esperam
# duas assinaturas. Voltar para a versão que estava em uso IMEDIATAMENTE antes
# não aprova nada de novo: aquele conteúdo já foi publicado e ativado com
# assinaturas nesta cidade. Por isso dispensa assinatura — e por isso é
# estreita:
#   - só a ativação ANTERIOR à atual, por protocolo;
#   - só se a ativação atual foi assinada: reverter uma reversão reativaria a
#     versão com erro sem assinatura nenhuma;
#   - só se a versão anterior ainda está publicada (não aposentada);
#   - motivo obrigatório, gravado na linha e no evento.
#
# Concorrência (P2): a leitura pré-trava de `current`, do histórico de
# ativações e de `target` pode estar obsoleta quando este command escreve —
# um Retire, um Activate ou outra RevertActivation concorrente pode ter
# mudado qualquer uma das duas linhas entre a leitura e a escrita. Por isso as
# DUAS linhas (a atual e a anterior) são travadas dentro da transação, em
# ordem determinística por id — nunca a atual antes da anterior numa chamada
# e depois da anterior noutra —, o que evita deadlock contra outra reversão
# disputando as duas mesmas linhas. `lock!` recarrega cada instância a partir
# da linha realmente travada, então mesmo um `target` obsoleto (por exemplo
# lido antes de um Retire concorrente) passa a refletir o estado real assim
# que trava — e é contra esse estado, relido por inteiro (histórico de
# ativações incluso), que toda condição é reconferida antes de qualquer
# escrita.
#
# Step-up de MFA é do chamador.
#
# Result.ok(protocol_definition:) | Result.fail(:city_missing|:reason_required|
#   :not_found|:forbidden|:not_revertible|:no_previous_activation|:invalid)
module Protocols
  module RevertActivation
    def self.call(name:, by:, reason:, correlation_id: nil)
      return Result.fail(:city_missing) if Current.city.nil?
      return Result.fail(:reason_required, message: "a reversão de emergência exige um motivo") if reason.to_s.strip.empty?

      current = ProtocolDefinition.find_by(name: name, status: "active")
      return Result.fail(:not_found) if current.nil?
      return Result.fail(:forbidden) unless ProtocolPolicy.new(by, current).activate?

      # Fast fail on the un-locked read (avoids opening a transaction and
      # requerying activation history for the common case); re-checked in
      # full under the lock below, which is what actually guards the race.
      latest, previous = activation_history(name)
      unless latest&.protocol_definition_id == current.id && latest.kind == "signed"
        return Result.fail(:not_revertible,
                           message: "só se reverte uma ativação assinada; reversão de reversão é recusada")
      end
      return Result.fail(:no_previous_activation) if previous.nil?

      target = ProtocolDefinition.find(previous.protocol_definition_id)
      unless target.status == "published"
        return Result.fail(:not_revertible, message: "a versão anterior não está publicada (está #{target.status})")
      end

      failure = nil
      ApplicationRecord.transaction do
        # Trava as duas linhas em ordem determinística por id (nunca current
        # antes de target numa chamada concorrente e o inverso na outra), o
        # que evita deadlock. lock! recarrega cada instância a partir da
        # linha travada — mesmo um current/target obsoleto passa a refletir
        # o estado real assim que trava.
        [ current, target ].sort_by(&:id).each(&:lock!)

        unless current.status == "active"
          failure = Result.fail(:not_revertible, message: "a versão vigente mudou (está #{current.status})")
          raise ActiveRecord::Rollback
        end

        latest, previous = activation_history(name)
        unless latest&.protocol_definition_id == current.id && latest.kind == "signed"
          failure = Result.fail(:not_revertible,
                                message: "só se reverte uma ativação assinada; reversão de reversão é recusada")
          raise ActiveRecord::Rollback
        end

        if previous.nil? || previous.protocol_definition_id != target.id
          failure = previous.nil? ? Result.fail(:no_previous_activation) :
                                    Result.fail(:not_revertible, message: "a versão anterior mudou desde a leitura")
          raise ActiveRecord::Rollback
        end

        unless target.status == "published"
          failure = Result.fail(:not_revertible, message: "a versão anterior não está publicada (está #{target.status})")
          raise ActiveRecord::Rollback
        end

        # demove a atual ANTES de ativar a anterior, para a unique parcial
        # WHERE status='active' nunca ver duas active (mesma ordem de
        # Protocols::Activate).
        current.update!(status: "published")
        target.update!(status: "active", activated_at: Time.current)

        ProtocolActivation.create!(protocol_definition: target, kind: "emergency_revert",
                                   actor_id: by.id, actor_kind: by.actor_kind, reason: reason.to_s.strip)

        DomainEvents.publish("protocol.activation_reverted", **{
          protocol_key: name, from_version: current.version, to_version: target.version,
          reason: reason.to_s.strip, actor: by.id, actor_kind: by.actor_kind, correlation_id: correlation_id
        }.compact)
      end

      return failure if failure

      Result.ok(protocol_definition: target)
    rescue ActiveRecord::RecordInvalid => e
      Result.fail(:invalid, message: e.record.errors.full_messages.join(", "))
    end

    # Leitura pura das MESMAS três condições que `call` exige, para quem só
    # quer perguntar "reverteria?" sem reverter — hoje só o painel da cidade
    # (Admin::ProtocolsQuery, spec de assinaturas §5). Reusa
    # `activation_history` em vez de duplicar a consulta; não é a checagem que
    # decide um `call` de verdade — essa segue travando as duas linhas e
    # reconferindo tudo sob lock (P2, acima). Sem lock, esta resposta pode
    # ficar obsoleta assim que outra escrita comita — quem chama sabe disso.
    def self.revertible?(protocol)
      return false unless protocol.status == "active"

      latest, previous = activation_history(protocol.name)
      return false unless latest&.protocol_definition_id == protocol.id && latest.kind == "signed"
      return false if previous.nil?

      ProtocolDefinition.where(id: previous.protocol_definition_id, status: "published").exists?
    end

    def self.activation_history(name)
      ProtocolActivation.joins(:protocol_definition)
                        .where(protocol_definitions: { name: name })
                        .order(created_at: :desc).limit(2).to_a
    end
    private_class_method :activation_history
  end
end
