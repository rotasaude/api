# API-only. CORS aberto para os hosts conhecidos: qualquer cidade servível do
# catálogo (Plano 6 — a lista estática não enumera N cidades), os hosts
# reservados da plataforma (admin/api/auth/www) e o que estiver em
# ALLOWED_ORIGINS (ferramentas internas, testes).
#
# Webhook do WhatsApp NÃO precisa de CORS (request vem do servidor da Meta).
# credentials: true é obrigatório para o browser enviar/aceitar o cookie de
# sessão (ADR-0011). A resolução usa o cache do CityCatalog (TTL 30 s, teto de
# 500 entradas), então uma origem inventada não vira query por requisição.
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
      next true if CityCatalog.reserved_host?(host)

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
end
