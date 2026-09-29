# O texto do SMS de campanha é sempre este (ADR 0024, D6): nunca carrega o
# conteúdo do aviso nem identificador — aparece na tela de bloqueio.
module Campaigns
  module SmsText
    module_function

    def body(city)
      name = CityProfile.current&.name.presence || city.name
      "Secretaria de Saúde de #{name}: você tem um aviso novo. Acesse #{link(city)}"
    end

    def link(city)
      "#{CityPublicUrl.wpda(city)}avisos"
    end
  end
end
