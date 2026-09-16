# Período de quietude compartilhado (Plano 7, fix F1 da rodada final de
# revisão): quem pode confiar que TODOS os processos já pararam de servir uma
# cidade como ativa depois de CityLifecycle::Suspend.
#
# CityCatalog.reset_cache! (chamado por Suspend) só limpa o cache DESTE
# processo — o cache é por processo, com TTL de CityCatalog::CACHE_TTL.
# Outros processos web podem ter resolvido a cidade pouco antes da suspensão e
# continuam servindo, por até CACHE_TTL, o MESMO objeto City que carregaram —
# com o material de cifra de ANTES de qualquer rekey/rotação. CityResolution
# entrega esse objeto direto a CityConnection.with, que deriva dele tanto o
# contexto de cifra quanto Current.city.
#
# Por isso QUIET_PERIOD é o TTL DUAS vezes, não uma: do ponto de vista de um
# outro processo, a suspensão pode ter sido observada só perto do fim do TTL
# dele, e a partir daí ele ainda serve por mais um TTL inteiro.
#
# Consequência de ignorar isso (o Critical desta rodada): uma escrita
# determinística (Conversation#phone, Author#token) feita por um processo que
# ainda acha a cidade ativa, sob o material ANTIGO, nunca colide com uma
# leitura/escrita feita sob o material NOVO — os ciphertexts diferem, o índice
# único parcial do telefone ativo não dispara, e o atributo determinístico
# falha ABERTO (cria uma segunda linha) enquanto o não-determinístico ao menos
# levanta Errors::Decryption. Suspensão sozinha (status == "suspended") NÃO
# basta; suspensão + este período de espera é o que de fato exclui os outros
# processos.
#
# Usado por CityLifecycle::Offboard (dump final) e pelas rake tasks
# city:rekey / city:rotate_key (lib/tasks/city.rake) — a mesma checagem, um
# só lugar, para que as três não divirjam sobre o que "suspensa há tempo
# suficiente" significa.
module CityLifecycle
  module SuspensionGuard
    QUIET_PERIOD = CityCatalog::CACHE_TTL.seconds * 2

    def self.suspended_recently?(city)
      suspended_at = PlatformEvent.where(name: "city.suspended").where("payload->>'city_id' = ?", city.id)
                                  .maximum(:occurred_at)
      suspended_at.present? && suspended_at > QUIET_PERIOD.ago
    end
  end
end
