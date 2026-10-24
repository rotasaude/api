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

      status_of(registered_at: registration.registered_at, refused: registration.refused?, identified: identified, today: today)
    end

    # O mesmo, para cadastro ativo lido em tuplas (RegistryStatus, sem objeto).
    def status_of(registered_at:, refused:, identified:, today:)
      return "refused" if refused
      return "missing_identifier" unless identified

      ends = expires_on(registered_at)
      return "expired" if ends <= today

      (ends - today) <= DUE_SOON_DAYS ? "due_soon" : "valid"
    end

    # Dia do vencimento: o dia da última gravação + 24 meses (Date#>>; 29/02
    # + 24 meses = 28/02 ou 29/02, como o calendário manda).
    def expires_on(registered_at) = registered_at.in_time_zone.to_date >> MONTHS
  end
end
