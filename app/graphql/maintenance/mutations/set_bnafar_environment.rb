module Maintenance
  module Mutations
    # Módulo 27b (Q9, Q17): o ambiente do envio à BNAFAR da cidade, só fora de
    # produção (a API de manutenção nem existe lá). Sessão humana. Trocar para
    # `homologation` não pede TOTP; voltar para `production` pede o step-up
    # (`code`, Q39): faria um staging enviar dado fictício à BNAFAR real. O
    # código nunca entra na auditoria; faltando, vale como inválido.
    class SetBnafarEnvironment < CityMutation
      description "Troca o ambiente do envio à BNAFAR (homologation só fora de produção)."

      argument :environment, String, required: true
      argument :code, String, required: false, description: "TOTP do momento; obrigatório para trocar para production"

      def resolve(city_slug:, environment:, code: nil)
        in_city(city_slug: city_slug, event: "maintenance.bnafar.environment_changed", module_name: "bnafar",
                rejection_path: "environment", environment: environment,
                step_up_code: (::Bnafar::Environment.production?(environment) ? code.to_s : nil)) do |actor, _correlation_id|
          ::Bnafar::SetEnvironment.call(environment: environment, by: actor)
        end
      end
    end
  end
end
