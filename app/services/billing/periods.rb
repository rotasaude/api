# Competência por estabelecimento faturante (ADR 0039; plano do módulo 22,
# Desvios 3 e 4; contrato §13 E18 com a decisão da revisão final). Nasce
# aberta na primeira produção; a UBS nunca ganha uma. Quem grava procedimento
# trava a competência FOR SHARE; o fechamento a trava FOR UPDATE
# (Billing::Close): um espera o outro. Ordem de travas: competência →
# procedimento. A competência própria ABERTA (nunca fechada ou reaberta) vale,
# sem atraso. Sem ela, competência igual ou anterior à ÚLTIMA fechada do
# estabelecimento vai, atrasada, para a aberta mais antiga depois da última
# fechada — só se não houver nenhuma nasce a seguinte à última fechada. Nunca
# nasce competência no passado.
module Billing
  module Periods
    COMPETENCE = /\A\d{4}(0[1-9]|1[0-2])\z/
    MAX_ATTEMPTS = 24

    module_function

    def assign!(establishment, competence)
      return [ nil, false ] if establishment.aps?

      MAX_ATTEMPTS.times do
        own = BillingPeriod.where(**establishment.key, competence: competence).lock("FOR SHARE").first
        return [ own, false ] if own&.status == "open"

        last_closed = BillingPeriod.where(**establishment.key, status: "closed").maximum(:competence)
        target = if last_closed.nil? || competence > last_closed then competence
                 else BillingPeriod.where(**establishment.key, status: "open").where("competence > ?", last_closed).minimum(:competence) ||
                        following(last_closed)
                 end
        period = BillingPeriod.lock("FOR SHARE").find(find_or_create!(establishment, target).id)
        return [ period, target != competence ] if period.status == "open"
        # fechada entre a leitura e a trava (Billing::Close): relê tudo
      end
      raise ActiveRecord::RecordNotFound, "nenhuma competência aberta em #{MAX_ATTEMPTS} tentativas"
    end

    def find_or_create!(establishment, competence)
      BillingPeriod.find_by(**establishment.key, competence: competence) ||
        BillingPeriod.transaction(requires_new: true) { BillingPeriod.create!(**establishment.key, competence: competence) }
    rescue ActiveRecord::RecordNotUnique
      BillingPeriod.find_by!(**establishment.key, competence: competence)
    end

    def following(competence) = Date.strptime(competence, "%Y%m").next_month.strftime("%Y%m")
    private_class_method :find_or_create!
  end
end
