require "openssl"
require "erb"

# Simulador do e-SUS PEC para a prova em dev (ADR 0035): monta a URL como a
# tela de "sistemas externos" (docs/pesquisa/2026-10-11-pec-sistemas-externos.md)
# e assina com a chave gravada na cidade. Só a rota de development o usa
# (Dev::PecSimulatorsController); nunca roda em ambiente publicado.
# A chave sai só como HMAC na URL: nunca é impressa, logada nem posta na página.
module PecSimulator
  BASE_TEMPLATE = "http://%{slug}.localhost:3040".freeze

  module_function

  def signed_url(city:, professional:, citizen:, cnes:, at: Time.current,
                 base: format(ENV.fetch("PEC_SIMULATOR_CITY_BASE", BASE_TEMPLATE), slug: city.slug))
    key = CityConnection.with(city) { PecSetting.current&.hmac_key }
    raise ArgumentError, "cidade sem chave do PEC (rode db:seed)" if key.to_s.empty?

    query = { "documento-profissional" => professional, "documento-cidadao" => citizen, "cnes" => cnes }
            .filter_map { |name, value| (digits = value.to_s.gsub(/\D/, "")).empty? ? nil : "#{name}=#{digits}" }.join("&")
    unsigned = "#{base}/pec/timeline?#{query}&pec_timestamp=#{at.to_i}"
    "#{unsigned}&pec_sign=#{OpenSSL::HMAC.hexdigest('SHA256', key, unsigned)}"
  end

  # Os valores da semente (TimelineCrew): enfermeira, cidadã validada e o CNES da unidade dela.
  def defaults(city)
    CityConnection.with(city) do
      nurse = User.find_by(email_address: "enfermeira@#{city.slug}.demo")&.professional
      unit = nurse&.links&.active&.order(:started_at)&.first&.health_unit
      citizen = Citizen.not_erased.verification_level_verified.order(:created_at).first
      { professional: nurse&.cpf.to_s, citizen: citizen&.cpf.to_s, cnes: unit&.cnes.to_s, minutes_ago: "0" }
    end
  end

  def page(city:, form:, url:)
    h = ->(value) { ERB::Util.html_escape(value.to_s) }
    fields = { professional: "CPF/CNS do profissional", citizen: "CPF do cidadão (vazio = acesso pelo menu)",
               cnes: "CNES", minutes_ago: "Minutos atrás (6+ = vencida)" }
    inputs = fields.map { |name, label| %(<label>#{h.(label)} <input name="#{name}" value="#{h.(form[name])}"></label>) }.join
    frame = url ? %(<p><a href="#{h.(url)}" target="pec">Reenviar a mesma URL</a></p><iframe src="#{h.(url)}" name="pec" width="100%" height="600"></iframe>) : ""
    <<~HTML
      <!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><title>PEC simulado — #{h.(city.name)}</title>
      <style>body{font-family:system-ui,sans-serif;margin:1rem}label{display:block;margin:.25rem 0}iframe{border:1px solid #999}</style></head>
      <body><h1>PEC simulado (desenvolvimento) — #{h.(city.name)}</h1>
      <form method="get"><input type="hidden" name="city" value="#{h.(city.slug)}"><input type="hidden" name="go" value="1">#{inputs}
      <button>Abrir "sistemas externos"</button></form>#{frame}</body></html>
    HTML
  end
end
