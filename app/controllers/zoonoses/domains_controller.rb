# /zoonoses/domains (módulo 35b, ADR 0054; contrato §10, §11; Q10, Q11):
# Zoonoses::Json.domains (o `zoonoses_domains` da referência do app mais as
# listas do dashboard) e `units` (Q41): as unidades ativas de vigilância
# ambiental (id, name), por nome, para o canil e a campanha; e
# `vaccination_units` (Q43): todas as unidades ativas, de qualquer tipo, para
# o posto fixo e a dose de rotina. As duas só existem aqui: a referência do field-sync (esquema fechado) segue sem ela. Para reader? e quem lê a visita domiciliar em
# alguma equipe (o agente de campo); os outros → 403 missing_role. Com o gate
# `zoonoses` desligado → 403 feature_disabled (Q10). Vocabulário da cidade, sem
# dado de pessoa: sem trilha.
module Zoonoses
  class DomainsController < BaseController
    def show
      user = Current.user
      return forbid unless Access.reader?(user) || HomeVisits::Access.reads_somewhere?(user)
      return unless query_only!

      render json: Json.domains.merge(units: units, vaccination_units: vaccination_units)
    end

    private

    def units = unit_list(HealthUnit.active_units.where(kind: "environmental_surveillance"))

    def vaccination_units = unit_list(HealthUnit.active_units)

    def unit_list(scope) = scope.pluck(:id, :name).map { |id, name| { id: id, name: name } }
  end
end
