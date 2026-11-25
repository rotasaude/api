# A faixa de alerta do envio à BNAFAR (módulo 27b; contrato §3; Q16; R25):
# calculada na leitura, sem tabela, como o Rnds::Alert. Só contagens e uma data,
# nunca registro nem pessoa. O "hoje" e as 15:00 são do fuso corrente (o da
# cidade em CityConnection.with).
#
#   - `late`: as remessas de ONTEM (R = hoje - 1) do ambiente que não estão
#     `finished` a partir das 15:00 de hoje (LATE_HOUR; Q16). Soma 1 quando
#     não existe remessa nenhuma de R e `domains` (os domínios devidos em R,
#     Gate.domains_through, lidos pelo chamador fora da transação) não é vazio
#     (R25: o envio parado antes de montar, ex. credencial recusada o dia
#     todo, também atrasa);
#   - `lost`: registros NÃO aceitos de remessas `lost` com `reference_on` nos
#     últimos CORRECTION_DAYS (30) dias;
#   - `rejected`: registros recusados das remessas de R (ainda reenviáveis);
#   - `last_finished_on`: o dia de referência da última remessa `finished`.
module Bnafar
  module Alert
    module_function

    # -> { late:, lost:, rejected:, last_finished_on: }
    def call(environment:, now:, domains: [])
      local = now.in_time_zone
      today = local.to_date
      yesterday = BnafarSubmission.where(environment: environment, reference_on: today - 1)
      { late: late(yesterday, local, domains),
        lost: lost(environment, today),
        rejected: BnafarRecord.where(bnafar_submission_id: yesterday.select(:id), status: "rejected", replaces_record_id: nil).count,
        last_finished_on: BnafarSubmission.where(environment: environment, status: "finished").maximum(:reference_on) }
    end

    def late(yesterday, local, domains)
      return 0 if local.hour < Catalog::LATE_HOUR

      return yesterday.where.not(status: "finished").count if yesterday.exists?

      Array(domains).empty? ? 0 : 1
    end

    def lost(environment, today)
      submissions = BnafarSubmission.where(environment: environment, status: "lost", reference_on: (today - Catalog::CORRECTION_DAYS)..)
      BnafarRecord.where(bnafar_submission_id: submissions.select(:id)).where.not(status: "accepted").where(replaces_record_id: nil).count
    end

    private_class_method :late, :lost
  end
end
