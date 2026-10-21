# Competência por estabelecimento faturante (ADR 0039; plano do módulo 22,
# Desvios 3 e 4). Nasce aberta na primeira produção; a UBS nunca ganha uma.
# Quem grava procedimento trava a competência FOR SHARE; o fechamento a trava
# FOR UPDATE (Billing::Close): um espera o outro. Ordem de travas:
# competência → procedimento. Fechada, o procedimento vai para a próxima
# competência aberta do estabelecimento, atrasado.
module Billing
  module Periods
    COMPETENCE = /\A\d{4}(0[1-9]|1[0-2])\z/
    MAX_AHEAD = 24

    module_function

    def assign!(establishment, competence)
      return [ nil, false ] if establishment.aps?

      current = competence
      MAX_AHEAD.times do
        period = BillingPeriod.lock("FOR SHARE").find(find_or_create!(establishment, current).id)
        return [ period, current != competence ] if period.status == "open"

        current = following(current)
      end
      raise ActiveRecord::RecordNotFound, "nenhuma competência aberta em #{MAX_AHEAD} meses"
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
