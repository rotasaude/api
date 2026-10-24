# Situação de um cadastro individual (módulo 24a, F-24.6; contrato §1, §6;
# §14 L5, L19). Ordem: saída → recusa → sem CPF e sem CNS
# (missing_identifier: a equipe precisa obter o CNS, a ficha não nasce) →
# vencido (24 meses contados do DIA da última gravação save/identity_refresh,
# o registered_at do cabeçalho; nunca a saída) → a vencer (até 60 dias antes)
# → válido. O dia é o da cidade (Time.zone). `identified:` vem de quem chama
# (CPF ou CNS presente) para a lista e a contagem decidirem em lote, sem
# decifrar o paciente.
module TerritoryRegistry
  module Validity
    MONTHS = 24
    DUE_SOON_DAYS = 60

    module_function

    def status(registration, today:, identified:)
      return "exited" if registration.exit_reason.present?
      return "refused" if registration.refused?
      return "missing_identifier" unless identified

      expires_on = registration.registered_at.in_time_zone.to_date >> MONTHS
      return "expired" if expires_on <= today

      (expires_on - today) <= DUE_SOON_DAYS ? "due_soon" : "valid"
    end
  end
end
