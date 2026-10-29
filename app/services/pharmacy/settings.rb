# Parâmetros da farmácia da cidade (ADR 0045): validade da receita, intervalo
# do uso contínuo, alerta de vencimento e limite de ajuste. Sem cache: lido por
# requisição (o admin muda e a próxima dispensação já vale).
module Pharmacy
  module Settings
    module_function

    # -> PharmacySetting (a linha única; os padrões entram se ela falta)
    def current = PharmacySetting.current
  end
end
