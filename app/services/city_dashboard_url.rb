# URLs do dashboard de uma cidade (Planos 3B e 4): a entrada com grant, para onde o
# console e o callback do gov.br mandam o navegador, e o link do convite do
# primeiro municipal_admin. O host por cidade vem de CityPublicUrl (Plano 6).
module CityDashboardUrl
  module_function

  def for(city, grant:)
    "#{base(city)}?#{{ grant: grant }.to_query}"
  end

  def invitation(city, token:)
    "#{base(city)}?#{{ invite: token }.to_query}"
  end

  def base(city)
    CityPublicUrl.dashboard(city)
  end
end
