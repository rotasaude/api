# API-only. CORS aberto para os hosts que a plataforma publica:
#   - cidade: a Origin precisa ser IDÊNTICA a CITY_PUBLIC_BASE_TEMPLATE com o
#     slug interpolado, e a cidade precisa estar servível no catálogo;
#   - console (admin.*), callback (auth.*) e ferramentas internas: lista
#     explícita em ALLOWED_ORIGINS — o console usa outro host/porta, que o
#     template de cidade não descreve.
#
# A comparação exata vem ANTES da consulta ao catálogo: origem de domínio alheio
# é recusada sem tocar o banco. Uma origem com a NOSSA forma e slug inexistente
# ainda consulta o catálogo por requisição — `find_by_host` não memoiza miss, de
# propósito (cidade em provisionamento não pode ficar presa em 404). É a mesma
# consulta que CityResolution já faz para um Host inventado: sem superfície nova.
# Webhook do WhatsApp não precisa de CORS (request vem do servidor da Meta).
# credentials: true é obrigatório para o cookie de sessão (ADR-0011).
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins do |source, _env|
      next true if ENV.fetch("ALLOWED_ORIGINS", "").split(",").map(&:strip).include?(source)

      host = begin
        URI.parse(source).host
      rescue URI::InvalidURIError
        nil
      end
      next false if host.blank?

      slug = host.split(".").first.to_s.downcase
      next false if slug.blank? || CityCatalog::RESERVED.include?(slug)
      # Igualdade exata com o host que NÓS publicamos para esse slug: um domínio
      # de terceiro que só imita o primeiro rótulo (slug.attacker.example) não
      # passa, e uma origem inventada é recusada ANTES de consultar o catálogo.
      next false unless source == CityPublicUrl.base_for_slug(slug)

      CityCatalog.find_by_host(host)&.servable? || false
    end
    resource "/protocols/*",
             headers: :any,
             methods: %i[get post options],
             expose: ["Authorization"]
    resource "/session",
             headers: :any,
             methods: %i[get post delete options],
             credentials: true
    resource "/admin/api/*",
             headers: :any,
             methods: %i[get options],
             credentials: true
  end

  # Frontend da API de manutenção: origem ÚNICA e exata, com credenciais (o
  # cookie de sessão). Bloco próprio, e não uma entrada em ALLOWED_ORIGINS,
  # porque aquela lista também libera /session e /admin/api do console.
  allow do
    origins ENV.fetch("MAINTENANCE_FRONTEND_ORIGIN", "")
    resource "/session",
             headers: :any,
             methods: %i[get post delete options],
             credentials: true
    resource "/session/challenge",
             headers: :any,
             methods: %i[post options],
             credentials: true
    resource "/invitations/*",
             headers: :any,
             methods: %i[get post options],
             credentials: true
  end
end
