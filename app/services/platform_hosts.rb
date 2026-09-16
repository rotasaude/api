# Hosts aceitos pelo ActionDispatch::HostAuthorization (Plano 8). Derivam do
# mesmo template público das cidades (CITY_PUBLIC_BASE_TEMPLATE), para não
# existir uma segunda fonte de verdade do domínio.
#
# Lista VAZIA desliga o middleware: é por isso que produção precisa declarar.
module PlatformHosts
  module_function

  def for(env)
    return [] unless env.to_s == "production"

    domain = URI.parse(CityPublicUrl.base_for_slug("x")).host.to_s.delete_prefix("x.")
    return [] if domain.blank?

    [ domain, ".#{domain}" ]
  end
end
