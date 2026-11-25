# Troca o ambiente do envio à BNAFAR da cidade (módulo 27b; Q9), pelo
# maintenance, dentro da conexão da cidade (CityMutation#in_city). `homologation`
# só fora de produção (Environment.allowed?); em produção o ambiente em uso é
# sempre `production` (Environment.current não lê a tabela) e esta escrita
# recusa o resto. Grava o mantenedor que trocou por último (uuid da plataforma).
module Bnafar
  module SetEnvironment
    module_function

    # -> Result.ok(environment:) | fail(:environment_not_allowed)
    def call(environment:, by:, env: Rails.env)
      return Result.fail(:environment_not_allowed, message: "environment_not_allowed") unless Bnafar::Environment.allowed?(environment, env: env)

      setting = BnafarSetting.current
      setting.update!(environment: environment, updated_by_maintainer_id: by.id, updated_at: Time.current)
      Result.ok(environment: environment)
    end
  end
end
