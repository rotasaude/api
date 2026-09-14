# URLs do dashboard de uma cidade (Planos 3B e 4): a entrada com grant, para onde o
# console e o callback do gov.br mandam o navegador, e o link do convite do
# primeiro municipal_admin. O host por cidade vem de um template porque os
# frontends ainda não têm host por cidade (Plano 6).
module CityDashboardUrl
  DEFAULT_TEMPLATE = "http://%{slug}.localhost:5175/dashboard/"

  module_function

  def for(city, grant:)
    "#{base(city)}?#{{ grant: grant }.to_query}"
  end

  # A tela que lê `invite` é do Plano 6; até lá o aceite é POST /setup/accept_invitation.
  def invitation(city, token:)
    "#{base(city)}?#{{ invite: token }.to_query}"
  end

  def base(city)
    format(ENV.fetch("CITY_DASHBOARD_URL_TEMPLATE", DEFAULT_TEMPLATE), slug: city.slug)
  end
end
