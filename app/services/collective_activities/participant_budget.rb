# Orçamento dos participantes novos da atividade coletiva da equipe (módulo
# 24b, ADR 0052; Q68, que refina a Q67; revisão final B-I1): cada participante
# `new_patient` roda a busca de duplicados e a checagem de CPF/CNS, então
# consome 1 unidade de um orçamento SEPARADO de 200 por minuto por usuário (só
# participantes de atividade; não o de 30/min do HomeVisits::SearchBudget).
# As N unidades da escrita são cobradas de uma vez, num só
# Rails.cache.increment(chave, N) — atômico no Solid Cache e no MemoryStore —
# antes de qualquer escrita, trava ou trilha. Não cabem → a escrita inteira é
# recusada (429 too_many_requests). Como no `rate_limit` do Rails, a tentativa
# recusada também conta (sem estorno): N acima de 200 numa escrita só nunca
# cabe. Sem contagem (cache nulo) aceita.
module CollectiveActivities
  class ParticipantBudget
    RATE = 200
    WINDOW = 1.minute
    SCOPE = "collective_activity_participants".freeze

    def self.cache_key(user_id) = "rate-limit:#{SCOPE}:#{user_id}"

    def initialize(user)
      @user = user
    end

    # -> true (as `units` couberam, já cobradas) | false (estourou)
    def reserve!(units)
      return true if units <= 0

      count = Rails.cache.increment(self.class.cache_key(@user.id), units, expires_in: WINDOW)
      count.nil? || count <= RATE
    end
  end
end
