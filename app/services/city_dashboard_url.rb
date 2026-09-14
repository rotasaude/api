# URL do dashboard de uma cidade com um grant, para onde o console e o callback
# do gov.br mandam o navegador (Plano 3B). O host por cidade vem de um template
# porque os frontends ainda não têm host por cidade (Plano 6).
module CityDashboardUrl
  DEFAULT_TEMPLATE = "http://%{slug}.localhost:5175/dashboard/"

  module_function

  def for(city, grant:)
    base = format(ENV.fetch("CITY_DASHBOARD_URL_TEMPLATE", DEFAULT_TEMPLATE), slug: city.slug)
    "#{base}?#{{ grant: grant }.to_query}"
  end
end
