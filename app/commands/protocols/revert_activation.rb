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
#   :not_found|:expected_version_required|:forbidden|:current_version_changed|
#   :not_revertible|
#   :no_previous_activation|:invalid)
module Protocols
  module RevertActivation
    def self.call(name:, by:, reason:, expected_version:, correlation_id: nil)
      return Result.fail(:city_missing) if Current.city.nil?
      return Result.fail(:reason_required, message: "a reversão de emergência exige um motivo") if reason.to_s.strip.empty?

      current = ProtocolDefinition.find_by(name: name, status: "active")
      return Result.fail(:not_found) if current.nil?

      # O que a TELA via quando a pessoa decidiu, contra o que vale agora.
      # Divergiram: outra ativação comitou entre a leitura e o clique, e a
      # decisão foi tomada sobre informação que não vale mais. Vem antes da
      # política para um token errado não virar :forbidden por acaso.
      #
      # UMA conferência, e de propósito: repeti-la dentro da transação seria
      # código morto. `current` é esta mesma linha, travada e não
      # re-resolvida — a `version` dela não muda —, e se outra versão tiver
      # sido ativada no meio do caminho, Protocols::Activate demove esta para
      # `published` antes (o índice único parcial em status='active' não
      # admite duas), de modo que o `unless current.status == "active"` que já
      # existe lá embaixo dispara primeiro — com esta mesma recusa.
      #
      # `expected_version` é OBRIGATÓRIO desde o passo 3 do rollout (spec
      # 2026-09-25 §5, api#11): sem ele não há como saber se a decisão foi
      # tomada sobre o estado atual. A palavra-chave não tem default — omiti-la
      # é erro de programação —, e `nil` (cliente que não mandou nada) é
      # recusa própria, distinta da divergência: a tela não tem o que reler.
      # O schema GraphQL continua com o argumento anulável de propósito: um
      # `Int!` quebraria na validação o console publicado, que declara
      # `$expectedVersion: Int`, e a recusa aqui fecha o caminho do mesmo jeito.
      # Só a AUSÊNCIA da chave é ausência de token: `""` e `"  "` são blank?,
      # e um `present?` aqui deixaria um cliente que calculou mal a versão
      # DESLIGAR a guarda em silêncio, em vez de falhar alto.
      #
      # `exception: false` porque `Integer("abc")` levanta ArgumentError, que o
      # Rails traduz em 500 — inaceitável num endpoint de emergência, e pior:
      # a tela mostraria "tente de novo", que é a dica errada. Token ilegível
      # é tratado como DIVERGÊNCIA, não como ausência: não dá para afirmar que
      # quem mandou aquilo estava vendo o estado atual.
      #
      # Base 10 explícita porque a automática lê "010" como octal (8): uma
      # versão 10 mandada com zero à esquerda recusaria uma reversão legítima
      # dizendo um número que confere com o que a pessoa mandou.
      if expected_version.nil?
        return Result.fail(:expected_version_required,
                           message: "a reversão exige a versão que a tela mostrava em uso")
      end
      seen = Integer(expected_version.to_s.strip, 10, exception: false)
      if seen != current.version
        return Result.fail(:current_version_changed,
                           message: "a versão em uso agora é a #{current.version}")
      end

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

        # A mesma corrida que o `expected_version` pega lá em cima, só que
        # comitada depois da leitura rápida: para quem clicou é o mesmo evento,
        # então é a mesma recusa (409, a tela relê e nomeia a versão). A outra
        # transação já comitou — é por isso que este ramo disparou —, então a
        # releitura enxerga a versão que passou a valer; pode não haver
        # nenhuma (um Retire), e a mensagem degrada em vez de interpolar nada.
        unless current.status == "active"
          now_active = ProtocolDefinition.find_by(name: name, status: "active")
          failure = Result.fail(:current_version_changed,
                                message: now_active ? "a versão em uso agora é a #{now_active.version}" :
                                                      "nenhuma versão está em uso agora")
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

    # A versão que voltaria a valer, ou nil. Leitura pura das MESMAS três
    # condições que `call` exige (spec 2026-09-23-revert-target §3):
    # a versão tem de estar em uso, a ativação corrente tem de ser dela e
    # assinada (linha-base não reverte: não há passo anterior), e a ativação
    # anterior tem de apontar para uma versão ainda `published`.
    #
    # Sem lock: a resposta pode ficar obsoleta assim que outra escrita comita —
    # quem chama sabe disso, e as telas dizem "deve voltar", não "vai voltar".
    def self.revert_target(protocol)
      return nil unless protocol.status == "active"

      latest, previous = activation_history(protocol.name)
      return nil unless latest&.protocol_definition_id == protocol.id && latest.kind == "signed"
      return nil if previous.nil?

      ProtocolDefinition.find_by(id: previous.protocol_definition_id, status: "published")
    end

    # Uma fonte só: quem pergunta "reverteria?" recebe a resposta derivada do
    # ALVO, e não de uma consulta paralela que poderia divergir dele.
    def self.revertible?(protocol)
      revert_target(protocol).present?
    end

    # O desempate por `id` existe porque este método roda DUAS vezes na mesma
    # reversão — a leitura rápida sem lock e a reconferência sob lock. Com
    # `created_at` empatado e a ordem incompleta, as duas execuções do mesmo
    # SQL podem devolver ordens diferentes, e o alvo conferido deixa de ser o
    # alvo revertido.
    #
    # Ele compra DETERMINISMO, não cronologia: `id` é UUID (gen_random_uuid),
    # então num empate a linha escolhida é estável e arbitrária — não a mais
    # recente. Num empate de microssegundo não existe ordem a respeitar; o que
    # existe é consistência a garantir. Quem um dia precisar da cronologia de
    # verdade precisa de uma coluna de sequência, não deste `id`.
    def self.activation_history(name)
      ProtocolActivation.joins(:protocol_definition)
                        .where(protocol_definitions: { name: name })
                        .order(created_at: :desc, id: :desc).limit(2).to_a
    end
    private_class_method :activation_history
  end
end
