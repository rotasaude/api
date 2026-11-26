# GET /pharmacy/bnafar/status (módulo 27b; contrato §3, §6; Q16): o alerta e os
# últimos 30 dias do ambiente em uso, uma linha por assunto com a contagem dos
# registros. Quem: `municipal_admin` ou `stock_keeper` de qualquer local. Só
# contagens: nenhum registro, payload ou pessoa. Query com qualquer chave → 422.
module Pharmacy
  module Bnafar
    class StatusController < BaseController
      DAYS = ::Bnafar::Catalog::CORRECTION_DAYS

      def show
        return unless bnafar_reader!
        return unless query_only!

        today = Time.zone.today
        due = ::Bnafar::Gate.domains_due(Current.city, today - 1)
        submissions = BnafarSubmission.where(environment: environment, reference_on: (today - DAYS)..).order(reference_on: :desc, subject: :asc).to_a
        render json: { environment: environment,
                       alert: ::Bnafar::Alert.call(environment: environment, now: Time.current, domains: due),
                       days: ::Bnafar::Json.days(submissions) }
      end
    end
  end
end
