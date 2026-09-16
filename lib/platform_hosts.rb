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

  class BlankDomain < StandardError; end

  module_function

  def for(env)
    return [] unless env.to_s == "production"

    template = ENV.fetch("CITY_PUBLIC_BASE_TEMPLATE", DEFAULT_TEMPLATE)
    domain = URI.parse(format(template, slug: "x")).host.to_s.delete_prefix("x.")
    if domain.blank?
      raise BlankDomain, "PlatformHosts: domínio vazio a partir de CITY_PUBLIC_BASE_TEMPLATE=#{template.inspect} " \
                          "— HostAuthorization ficaria sem guarda em produção"
    end

    [ domain, ".#{domain}" ]
  end
end
