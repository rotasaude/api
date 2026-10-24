# Pares do paciente (ADR 0031/0042): validados e não excluídos, ligados a ele
# ou — só quando ele tem CPF — com o CPF dele (o par validado que ainda não se
# ligou). Paciente sem CPF não tem par pelo CPF.
module Patients
  module Pairs
    module_function

    def of(patient)
      linked = base.where(patient_id: patient.id)
      patient.cpf.present? ? linked.or(base.where(cpf: patient.cpf)) : linked
    end

    def of_cpf(cpf) = base.where(cpf: cpf)

    # Ids dos pacientes que têm algum par pela regra do `of` (ligado, ou com o
    # CPF dele), numa consulta só — para listas que mostram a marca.
    def patient_ids_with_pairs(patients)
      patients = patients.to_a
      return Set.new if patients.empty?

      cpfs = patients.filter_map { |patient| patient.cpf.presence }
      rows = base.where(patient_id: patients.map(&:id)).or(base.where(cpf: cpfs)).pluck(:patient_id, :cpf)
      linked = rows.filter_map(&:first).to_set
      by_cpf = rows.filter_map(&:last).to_set
      patients.select { |patient| linked.include?(patient.id) || (patient.cpf.present? && by_cpf.include?(patient.cpf)) }
              .to_set(&:id)
    end

    def base = Citizen.not_erased.verification_level_verified
  end
end
