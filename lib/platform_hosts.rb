# Hosts aceitos pelo ActionDispatch::HostAuthorization (Plano 8). Deriva do
# mesmo template público das cidades (CITY_PUBLIC_BASE_TEMPLATE) — não existe
# uma segunda fonte de verdade do domínio.
#
# Fica em lib/, não em app/services/, e é `require`ado explicitamente por
# config/environments/production.rb (e pelo próprio spec). Aquele arquivo é
# lido pelo initializer :load_environment_config, que roda ANTES do Zeitwerk
# (:setup_main_autoloader só roda no Finisher, bem mais tarde) — então nenhuma
# constante autoloaded pode ser referenciada aqui nesse momento. Isso inclui
# CityPublicUrl (app/services/): por isso este módulo lê CITY_PUBLIC_BASE_TEMPLATE
# direto em vez de chamar CityPublicUrl.base_for_slug — mesma env var, mesmo
# formato, sem depender do autoloader. Ver spec/architecture/host_authorization_spec.rb.
#
# Lista VAZIA desliga o middleware: é por isso que produção precisa declarar, e
# por isso um domínio vazio levanta em vez de devolver [] silenciosamente — seria
# a mesma falha que este módulo existe para evitar, só que disfarçada de sucesso.
module PlatformHosts
  DEFAULT_TEMPLATE = "http://%{slug}.localhost:5175"

  # Slug sintético: o domínio da plataforma é o que sobra do host depois de
  # tirar o rótulo da cidade, então formatamos o template com um slug qualquer
  # e removemos o rótulo que ele ocupa.
  SENTINEL_SLUG = "x"

  class BlankDomain < StandardError; end

  # A derivação acima só vale se o slug for o PRIMEIRO rótulo do host. Num
  # template como "https://%{slug}-cidades.rota.example" ela não removeria nada
  # e devolveria "x-cidades.rota.example" — um domínio errado, não vazio, que a
  # guarda de BlankDomain deixa passar. Produção subiria com config.hosts
  # mentiroso: aceitando um host que não é nosso e recusando os que são.
  class UnexpectedTemplate < StandardError; end

  module_function

  def for(env)
    return [] unless env.to_s == "production"

    template = ENV.fetch("CITY_PUBLIC_BASE_TEMPLATE", DEFAULT_TEMPLATE)
    host = URI.parse(format(template, slug: SENTINEL_SLUG)).host.to_s
    prefix = "#{SENTINEL_SLUG}."

    if host.present? && !host.start_with?(prefix)
      raise UnexpectedTemplate, "PlatformHosts: CITY_PUBLIC_BASE_TEMPLATE=#{template.inspect} não põe o slug como " \
                                "primeiro rótulo do host (derivou #{host.inspect}) — o domínio da plataforma sairia " \
                                "errado e o HostAuthorization recusaria justamente os hosts reais"
    end

    domain = host.delete_prefix(prefix)
    if domain.blank?
      raise BlankDomain, "PlatformHosts: domínio vazio a partir de CITY_PUBLIC_BASE_TEMPLATE=#{template.inspect} " \
                          "— HostAuthorization ficaria sem guarda em produção"
    end

    [ domain, ".#{domain}" ]
  end
end
