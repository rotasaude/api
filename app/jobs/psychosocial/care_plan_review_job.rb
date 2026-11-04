# Job diário das revisões vencidas do PTS (ADR 0049; contrato P16): por cidade
# (EachCityJob), só com `psychosocial_care` utilizável (lido fora de qualquer
# transação da cidade). Para a versão mais nova de cada matrícula aberta cuja
# `review_on` já passou, grava UM aviso (psychosocial_care_plan_alerts, único
# por versão) e publica `psychosocial.care_plan_review_due` com o id — uma vez
# por versão, mesmo rodando duas vezes no dia. A caixa da equipe é a rota
# `care_plans/due`; nada vai ao cidadão. A falha de uma versão não para as
# outras: vai ao log só com o id e a classe do erro, e o job falha no fim com a
# contagem. Log de sucesso só com contagens.
module Psychosocial
  class CarePlanReviewJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    def perform
      return unless Gate.usable?(Current.city)

      alerted = 0
      failed = 0
      CarePlanReview.unalerted_overdue_plan_ids(today: Time.zone.today).each do |plan_id|
        alerted += 1 if alert!(plan_id)
      rescue => e
        failed += 1
        Rails.logger.error("[#{self.class.name}] care_plan=#{plan_id} failed: #{e.class}")
      end
      Rails.logger.info("[#{self.class.name}] city=#{Current.city.slug} alerted=#{alerted} failed=#{failed}")
      raise "#{failed} care plan alert(s) failed" if failed.positive?
    end

    private

    # O índice único é a idempotência: já avisada, o insert não grava nem publica.
    def alert!(plan_id)
      ApplicationRecord.transaction(requires_new: true) do
        inserted = PsychosocialCarePlanAlert.insert_all([ { psychosocial_care_plan_id: plan_id, created_at: Time.current } ],
                                                        unique_by: :psychosocial_care_plan_id)
        next false if inserted.rows.empty?

        DomainEvents.publish("psychosocial.care_plan_review_due", care_plan_id: plan_id)
        true
      end
    end
  end
end
