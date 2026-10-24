# Equipe da pessoa pelo cadastro individual (módulo 24a, ADR 0042; contrato
# §9; F-24.8). Cadastro ativo (sem saída) de equipe ativa → a equipe do
# cabeçalho: a da microárea do domicílio (o SaveRegistration a copia e a
# cascata do SaveHousehold a mantém; a equipe da microárea nunca muda) ou,
# sem domicílio, a do cadastro fora de área (Desvio 3). Vale desde a
# gravação, sem esperar a resposta do SIAPS. Saída (moved | death) não conta.
# Uma consulta; quem decide se a regra vale é o TeamPopulation (Gate).
module TerritoryRegistry
  module Teams
    module_function

    # { patient_id => team_id }. `team:` restringe aos cadastrados dela.
    def for_patients(patient_ids = nil, team: nil)
      return {} if patient_ids && patient_ids.empty?

      scope = IndividualRegistration.active_registrations.joins(:team).where(health_teams: { active: true })
      scope = scope.where(patient_id: patient_ids) if patient_ids
      scope = scope.where(team_id: team.id) if team
      scope.pluck(:patient_id, :team_id).to_h
    end
  end
end
