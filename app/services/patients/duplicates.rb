# Possíveis duplicados de um paciente digitado (ADR 0042; Desvio 1): pela
# chave cega (nome normalizado + nascimento) e, com o nome da mãe, pelos
# candidatos cuja mãe normalizada é a mesma (filtro depois de decifrar —
# a mãe não entra na chave). Mais antigos primeiro, no máximo `limit`.
module Patients
  module Duplicates
    MAX = 10

    module_function

    def call(full_name:, birth_date:, mother_name: nil, limit: MAX)
      key = MatchKey.for(full_name, birth_date)
      return [] if key.nil?

      scope = Patient.where(match_key: key).order(:created_at, :id)
      mother = MatchKey.normalize(mother_name)
      return scope.limit(limit).to_a if mother.nil?

      scope.select { |patient| MatchKey.normalize(patient.mother_name) == mother }.first(limit)
    end
  end
end
