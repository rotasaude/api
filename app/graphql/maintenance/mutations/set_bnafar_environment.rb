module Maintenance
  module Mutations
    # Módulo 27b (Q9, Q17): o ambiente do envio à BNAFAR da cidade, só fora de
    # produção (a API de manutenção nem existe lá). Sem TOTP, como
    # setCityPecOrigin: não é credencial nem põe nada em uso real.
    class SetBnafarEnvironment < CityMutation
      description "Troca o ambiente do envio à BNAFAR (homologation só fora de produção)."

      argument :environment, String, required: true

      def resolve(city_slug:, environment:)
        in_city(city_slug: city_slug, event: "maintenance.bnafar.environment_changed", module_name: "bnafar",
                rejection_path: "environment", environment: environment) do |actor, _correlation_id|
          ::Bnafar::SetEnvironment.call(environment: environment, by: actor)
        end
      end
    end
  end
end
