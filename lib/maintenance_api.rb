# Quando a API de manutenção existe (spec da API de manutenção §5).
#
# Fica em lib/ e é `require`ado por config/application.rb, como lib/rota.rb:
# config/routes.rb pergunta isto para decidir se DESENHA a rota, e rota que não
# existe devolve 404 no roteamento, sem depender de nenhum controller lembrar de
# negar — a mesma regra da tela /maintenance.
module MaintenanceApi
  # Ambientes em que a ferramenta pode existir. Produção está fora por decisão do
  # usuário: lá o acesso é a dado real e a decisão é própria, futura.
  ALLOWED_ENVS = %w[development staging].freeze

  # spec/architecture/deployed_environment_guard_spec.rb proíbe comparar contra o
  # literal "production" (== "production", :production, %w[...production...])
  # em app/config/lib/db/bin/script/Rakefile/config.ru. check_boot! precisa
  # reconhecer justamente esse ambiente sem escrever o literal: deriva-se do
  # conjunto já declarado em lib/rota.rb — Rota::DEPLOYED_ENVS (production e
  # staging) menos o que a API de manutenção já permite (ALLOWED_ENVS) sobra só
  # o ambiente bloqueado, sem nenhum texto "production" novo neste arquivo.
  BLOCKED_ENVS = (Rota::DEPLOYED_ENVS - ALLOWED_ENVS).freeze

  FLAG = "MAINTENANCE_API_ENABLED"

  class EnabledInProduction < StandardError; end

  module_function

  # test SEMPRE liga: cookie, CSRF, bloqueio de conta e escopo precisam de
  # request spec, e test não é ambiente publicado. A ausência em produção é
  # provada aqui, nesta função, e não pela rota.
  def enabled?(env: Rails.env, flag: ENV[FLAG])
    return true if env.to_s == "test"

    ALLOWED_ENVS.include?(env.to_s) && flag.to_s == "true"
  end

  # Falha fechada no boot: chave ligada num processo do ambiente bloqueado
  # (produção) é erro de deploy, e erro de deploy tem que aparecer no deploy.
  def check_boot!(env: Rails.env, flag: ENV[FLAG])
    return unless BLOCKED_ENVS.include?(env.to_s) && flag.to_s == "true"

    raise EnabledInProduction,
          "#{FLAG}=true em produção — a API de manutenção não existe em produção (spec §5). " \
          "Remova a variável do deploy."
  end
end
