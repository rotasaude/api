# A pessoa avaliada (paciente ou par validado), com o que a elegibilidade e
# as faixas precisam, decifrado na leitura. inspect só com ids (contrato,
# convenção: Data com dado pessoal nunca mostra o dado).
module CareLines
  Person = Data.define(:patient_id, :citizen_id, :birth_date, :sex, :gender_identity, :problems, :resolved_problems, :declared, :team_id) do
    def initialize(patient_id: nil, citizen_id: nil, birth_date: nil, sex: nil, gender_identity: nil, problems: [],
                   resolved_problems: [], declared: [], team_id: nil) = super

    def age_years(on) = birth_date && Citizen.age_between(birth_date, on)
    def age_days(on) = birth_date && (on - birth_date).to_i
    def key = patient_id ? "patient:#{patient_id}" : "citizen:#{citizen_id}"
    def inspect = "#<CareLines::Person patient_id=#{patient_id.inspect} citizen_id=#{citizen_id.inspect}>"
    alias_method :to_s, :inspect
    def pretty_print(q) = q.text(inspect)
  end
end
