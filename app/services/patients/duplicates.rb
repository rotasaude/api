# Possíveis duplicados de um paciente digitado (ADR 0042; Desvio 1): pela
# chave cega (nome normalizado + nascimento) e, com o nome da mãe, filtrados
# depois de decifrar (a mãe não entra na chave): primeiro os de mãe
# normalizada igual, depois os sem mãe gravada (podem ser a mesma pessoa;
# revisão final, I3); mãe diferente fica de fora. Mais antigos primeiro
# dentro de cada grupo, no máximo `limit`.
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

      mothers = scope.to_a.group_by { |patient| MatchKey.normalize(patient.mother_name) }
      (mothers.fetch(mother, []) + mothers.fetch(nil, [])).first(limit)
    end
  end
end
