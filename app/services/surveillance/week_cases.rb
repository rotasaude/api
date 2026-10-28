# Quem teve caso na semana epidemiológica (módulo 25; contrato K7): a negativa
# semanal vale pela semana da SUSPEITA (suspected_on), e só conta como caso a
# notificação que passou da possível — possible (ainda não confirmada pela
# equipe) e dismissed (descartada) não tiram a obrigação da negativa. Uma regra
# só, para o lembrete (NegativesReminderJob) e para o painel de pendências.
# Só ids de unidade; nada do paciente.
module Surveillance
  module WeekCases
    NOT_A_CASE = %w[possible dismissed].freeze

    module_function

    # week: Surveillance::EpiWeek -> Set de health_unit_id.
    def unit_ids_with_cases(week)
      DiseaseNotification.where(suspected_on: week.range).where.not(status: NOT_A_CASE).distinct.pluck(:health_unit_id).to_set
    end
  end
end
