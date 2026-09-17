# Quem a tela de manutenção impersona numa cidade (development).
#
# Vive fora do controller pelo mesmo motivo estrutural do CityInventory: a rota
# /dev/impersonate só é desenhada em development e a suíte roda em test, então
# nenhum request spec a alcança. A escolha do alvo é a parte com regra — é ela
# que fica aqui, coberta por spec/services/dev_impersonation_spec.rb.
#
# O ALVO NÃO É ESCOLHÍVEL PELO CHAMADOR, e isso é a decisão central: sai da
# cidade da conexão corrente (o host resolveu a cidade antes, via
# CityResolution). Se ele viesse por parâmetro, "impersonar o admin desta
# cidade" e "impersonar qualquer conta" seriam a mesma rota com argumentos
# diferentes — e a segunda existiria de graça.
#
# Elegível é só quem já poderia entrar sozinho:
#   - papel municipal_admin ATIVO (revogar é end-date, não DELETE — a conta
#     continua existindo e autenticando por senha, mas sem o papel);
#   - conta não desativada (desativação é end-dating por ADR-0012 e destrói as
#     sessões existentes).
# Sem esses dois filtros, o atalho de dev viraria um jeito de ressuscitar acesso
# que o domínio já tirou — que é pior do que não existir.
module DevImpersonation
  ROLE = "municipal_admin".freeze

  module_function

  # A conta a impersonar na cidade da conexão corrente, ou nil quando não há
  # candidato. Nil em vez de levantar: o controller responde 404, que é a
  # resposta honesta para "a cidade existe, mas não há quem impersonar".
  #
  # Ordena por e-mail para ser determinístico: numa cidade com mais de um
  # administrador, o link precisa levar sempre à mesma conta, senão o estado que
  # você vê no dashboard muda sem motivo aparente entre dois cliques.
  def target
    User.where(deactivated_at: nil)
        .joins(:memberships)
        .where(memberships: { role: ROLE, revoked_at: nil })
        .order(:email_address)
        .first
  end
end
