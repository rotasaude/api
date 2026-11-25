# Ambiente do SI-BNAFAR em uso pela cidade (módulo 27b, Valor 10 e Q9). Em
# produção é SEMPRE `production`; fora dela, o que `bnafar_settings` diz. A
# tabela nasce na Task 10 (como `pec_settings` para o PecConfigState): enquanto
# não existe, `production`. Lê a conexão corrente, ou seja, a da cidade quando
# chamado dentro de `CityConnection.with`.
module Bnafar
  module Environment
    module_function

    def current(env: Rails.env)
      return "production" unless simulation_env?(env)

      connection = ApplicationRecord.connection
      return "production" unless connection.data_source_exists?("bnafar_settings")

      value = connection.select_value("SELECT environment FROM bnafar_settings LIMIT 1")
      Bnafar::Catalog::ENVIRONMENTS.include?(value) ? value : "production"
    end

    # `homologation` só se grava (credencial ou ambiente) fora de produção.
    def allowed?(value, env: Rails.env)
      return false unless Bnafar::Catalog::ENVIRONMENTS.include?(value)

      value != "homologation" || simulation_env?(env)
    end

    # Só dev, test e staging têm homologação; todo o resto é produção. (A guarda
    # de ambiente publicado proíbe comparar com "production": staging roda com
    # RAILS_ENV=staging e precisa poder homologar.)
    def simulation_env?(env) = Platform::Features::SIMULATION_ENVS.include?(env.to_s)
    private_class_method :simulation_env?
  end
end
