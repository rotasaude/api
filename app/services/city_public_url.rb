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

  # Em dev o wpda serve na porta 5176, não 5175 (um host só resolve os dois
  # caminhos em produção; em dev cada app Vite tem a sua porta). Plano 6
  # fix wave (Important #2): CITY_WPDA_BASE_TEMPLATE substitui o template
  # público só para este link quando presente; sem ela, comportamento
  # inalterado (mesmo template de base/dashboard).
  def wpda(city)
    raise CityMissing, "CityPublicUrl sem cidade no contexto" if city.nil?

    "#{wpda_base_for_slug(city.slug)}/wpda/"
  end

  def wpda_base_for_slug(slug)
    template = ENV["CITY_WPDA_BASE_TEMPLATE"].presence || ENV.fetch("CITY_PUBLIC_BASE_TEMPLATE", DEFAULT_TEMPLATE)
    format(template, slug: slug).chomp("/")
  end
end
