# RAAS do mês de uma matrícula (ADR 0049; plano, Desvio 6): o registro `open`
# de (matrícula, mês), criado uma vez (índice único, ON CONFLICT DO NOTHING) ao
# matricular (mês do início), ao gravar ação com o participante matriculado
# (Task 7) e no job do mês (Task 9). Mês com fechamento ativo no CAPS: devolve o
# existente sem criar (ou nil). Quem chama segura a linha do CAPS (FOR SHARE)
# antes, para não correr com o fechamento (ruling das Tasks 7 e 9).
module Psychosocial
  module MonthlyRecords
    module_function

    # month: qualquer dia do mês. -> PsychosocialMonthlyRecord | nil
    def ensure!(enrollment, month)
      month = month.to_date.beginning_of_month
      scope = PsychosocialMonthlyRecord.where(psychosocial_enrollment_id: enrollment.id, month: month)
      return scope.first if closed?(enrollment.health_unit_id, month)

      PsychosocialMonthlyRecord.insert_all(
        [ { psychosocial_enrollment_id: enrollment.id, health_unit_id: enrollment.health_unit_id, month: month, status: "open" } ],
        unique_by: %i[psychosocial_enrollment_id month]
      )
      scope.first!
    end

    # Fechamento ativo do CAPS no mês (qualquer dia do mês).
    def closed?(health_unit_id, month)
      PsychosocialMonthClosure.active.exists?(health_unit_id: health_unit_id, month: month.to_date.beginning_of_month)
    end
  end
end
