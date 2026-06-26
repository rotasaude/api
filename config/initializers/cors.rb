# API-only. CORS aberto apenas para os hosts conhecidos do frontend.
# Webhook do WhatsApp NÃO precisa de CORS (request vem do servidor da Meta).
#
# Em dev/prod o Admin Console é servido via reverse-proxy / Vite proxy
# (same-origin do ponto de vista do browser → cookies fluem sem CORS).
# As regras abaixo cobrem chamadas cross-origin explícitas (testes,
# ferramentas internas). credentials: true é obrigatório para que o
# browser envie/aceite o cookie de sessão (ADR-0022).
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins ENV.fetch("ALLOWED_ORIGINS", "http://localhost:5174,http://localhost:5173").split(",")
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
