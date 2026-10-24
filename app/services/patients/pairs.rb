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

    def base = Citizen.not_erased.verification_level_verified
  end
end
