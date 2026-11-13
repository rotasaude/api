# Orçamento da busca de pessoa (módulo 24b, ADR 0052; contrato §5, Q67;
# revisão final B-I1, LGPD): 30 por minuto por usuário, UM só para
#   - as buscas da tela (FieldPersonSearch: lookup e duplicates, em
#     /home_visits/people e /collective_activities/people);
#   - toda gravação que roda a busca de duplicados ou a checagem de CPF/CNS:
#     POST /home_visits (429 too_many_requests) e cada item do envio do app
#     (rejected too_many_requests, fora do livro). A atividade coletiva (POST
#     /collective_activities e o item collective_activity do envio) cobra o
#     seu, por participante novo (Q68: CollectiveActivities::ParticipantBudget).
# A chave e o Rails.cache.increment são os do `rate_limit` do Rails
# ("rate-limit:<scope>:<usuário>", sem `name`), então consumir num lado
# reduz o outro. Sem contagem (cache nulo) aceita, como o rate_limit.
# Paciente existente por patient_id não consome: quem cobra é quem roda a
# busca (HomeVisits::People.create e o cadastro do envio).
module HomeVisits
  class SearchBudget
    RATE = 30
    WINDOW = 1.minute
    SCOPE = "field_person_search".freeze

    def self.cache_key(user_id) = "rate-limit:#{SCOPE}:#{user_id}"

    # O orçamento já cobrado por quem chama (Q68: os participantes novos da
    # atividade coletiva, no CollectiveActivities::ParticipantBudget): o
    # People não cobra de novo.
    class Paid
      def charge! = true
    end
    PAID = Paid.new.freeze

    def initialize(user)
      @user = user
      @within = nil
    end

    # Uma cobrança por gravação ou item: a segunda chamada devolve a primeira
    # resposta (a atividade com vários participantes novos, a revisão do
    # duplicado que roda a busca de novo). -> true (dentro) | false (estourou)
    def charge!
      return @within unless @within.nil?

      count = Rails.cache.increment(self.class.cache_key(@user.id), 1, expires_in: WINDOW)
      @within = count.nil? || count <= RATE
    end
  end
end
