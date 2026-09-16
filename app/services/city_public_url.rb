# Host público de uma cidade e os caminhos que a API precisa apontar para ele
# (Plano 6). Uma env var só, com o slug interpolado: dashboard, wpda e o link de
# reset de senha saem daqui, em vez de três variáveis de host único
# (CITY_DASHBOARD_URL_TEMPLATE, PUBLIC_DASHBOARD_URL, WPDA_PUBLIC_BASE).
#
# Sem cidade no contexto o certo é levantar: um link montado com o host errado
# vai por WhatsApp ou e-mail e quebra sem erro nenhum no servidor.
module CityPublicUrl
  DEFAULT_TEMPLATE = "http://%{slug}.localhost:5175"

  class CityMissing < StandardError; end

  module_function

  def base(city)
    raise CityMissing, "CityPublicUrl sem cidade no contexto" if city.nil?

    base_for_slug(city.slug)
  end

  # Host público de um slug, sem precisar da linha do catálogo: o CORS compara a
  # Origin recebida com ESTA string antes de consultar o catálogo.
  def base_for_slug(slug)
    format(ENV.fetch("CITY_PUBLIC_BASE_TEMPLATE", DEFAULT_TEMPLATE), slug: slug).chomp("/")
  end

  def dashboard(city)
    "#{base(city)}/dashboard/"
  end

  def wpda(city)
    "#{base(city)}/wpda/"
  end
end
