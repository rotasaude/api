# Cadência do imóvel (módulo 35a, ADR 0054; contrato §5; W-2, A-11): os dias
# entre duas visitas, da linha mais específica de vector_cadences para a mais
# geral (bairro nulo = cidade, risco nulo = qualquer):
#   - ponto estratégico (property_type 4): (bairro, PE) → (cidade, PE) →
#     `strategic_point_days` dos parâmetros;
#   - demais: (bairro, risco) → (bairro, qualquer) → (cidade, risco) →
#     (cidade, qualquer) (o degrau do A-11) → `default_days`.
# `days_for` é pura: a tabela vem de `table` (uma consulta só, para a folha
# inteira) e os parâmetros de VectorControl::Parameters.current.values.
module VectorControl
  module Cadence
    module_function

    # -> Integer. `profile`: o perfil do imóvel (risk_class) ou nil; `household`:
    # o domicílio na versão atual (responde a property_type); `table`: o
    # Cadence.table; `parameters`: o Hash de valores dos parâmetros vigentes.
    def days_for(profile:, household:, neighborhood_id:, table:, parameters:)
      if household.property_type.to_s == Catalog::PE_PROPERTY
        steps = [ [ neighborhood_id, nil, true ], [ nil, nil, true ] ]
        fallback = "strategic_point_days"
      else
        risk = profile&.risk_class
        steps = [ [ neighborhood_id, risk, false ], [ neighborhood_id, nil, false ], [ nil, risk, false ], [ nil, nil, false ] ]
        fallback = "default_days"
      end
      steps.each do |key|
        days = table[key]
        return days if days
      end
      Integer(parameters.fetch(fallback))
    end

    # { [neighborhood_id, risk_class, strategic_point] => days } de todas as linhas.
    def table
      VectorCadence.pluck(:neighborhood_id, :risk_class, :strategic_point, :days).to_h { |nb, risk, sp, days| [ [ nb, risk, sp ], days ] }
    end
  end
end
