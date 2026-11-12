# Job diário da ouvidoria, às 10h de Brasília (ADR 0051; contrato §12; §16 Q11,
# Q36, Q59 — 8h no Acre, dentro da janela do SMS em todo fuso): por cidade
# (EachCityJob), só com `ombudsman` utilizável (lido fora de qualquer
# transação da cidade).
#   1. Marca o dia em ombudsman_daily_runs (único por dia e tipo): já marcado →
#      termina. A marca vem antes do trabalho (F-23): um tombo no meio perde só
#      o resumo do dia, e o arquivamento se cura no dia seguinte (o vencimento
#      continua casando, e o expected_state mantém cada um único).
#   2. Arquiva com `no_complement` (actor system, sem usuário) cada manifestação
#      em `awaiting_complement` cujo complemento venceu: a data local do pedido
#      mais complement_days já passou. Quem respondeu no último dia saiu do
#      estado e não casa. Archive é a única escrita do cidadão (evento e aviso).
#      A falha de uma não para as outras: log só com o id e a classe.
#   3. Enfileira os e-mails de resumo (Ombudsman::MailJob): só números.
module Ombudsman
  class DeadlinesJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    def perform
      return unless Gate.usable?(Current.city)

      today = Time.zone.today
      return unless first_run_of?(today)

      settings = OmbudsmanSetting.current
      archived, failed = archive_expired(settings, today)
      %w[daily_summary responder_summary].each do |kind|
        MailJob.perform_later(city_slug: Current.city.slug, kind: kind, ref: today.iso8601)
      end
      Rails.logger.info("[#{self.class.name}] city=#{Current.city.slug} archived=#{archived} failed=#{failed}")
      raise "#{failed} expired complement(s) failed" if failed.positive?
    end

    private

    def first_run_of?(today)
      OmbudsmanDailyRun.insert_all([ { run_on: today, kind: "deadlines", created_at: Time.current } ],
                                   unique_by: :idx_ombudsman_daily_runs_once).rows.any?
    end

    def archive_expired(settings, today)
      archived = failed = 0
      ids = OmbudsmanManifestation.where(Deadlines.complement_expired_sql(settings, today: today)).order(:received_at, :id).pluck(:id)
      ids.each do |id|
        result = Archive.call(manifestation_id: id, expected_state: "awaiting_complement", reason: "no_complement",
                              duplicate_of_id: nil, external_body_name: nil, by: nil, actor: "system")
        archived += 1 if result.ok?
      rescue => e
        failed += 1
        Rails.logger.error("[#{self.class.name}] manifestation=#{id} failed: #{e.class}")
      end
      [ archived, failed ]
    end
  end
end
