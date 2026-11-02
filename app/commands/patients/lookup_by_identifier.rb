# Busca de pessoa pelo CPF OU pelo CNS (contrato §13 H2 do 27a; §15 V3 do 29),
# extraída do Pharmacy::PersonLookupsController para a farmácia e a sala de
# vacina responderem igual. O par validado sem paciente vira paciente
# (Patients::Resolve, como o patient_lookup do 21a e o 24a).
#
#  - os dois → invalid_request (path cns); nenhum → invalid_request (path cpf);
#  - CPF: o paciente do CPF; senão o par validado do CPF (cria o paciente);
#    par só declarado → citizen_not_verified; ninguém → person_not_found;
#    CPF malformado → invalid_cpf (path cpf);
#  - CNS: só pacientes (o CNS do par é cifrado sem chave de busca); ninguém →
#    person_not_found; malformado → invalid_cns (path cns).
#
# Nada da pessoa em Result.details: só o path do campo.
module Patients
  module LookupByIdentifier
    module_function

    # -> Result.ok(patient:) | fail(:invalid_request | :invalid_cpf | :invalid_cns, details: { path: }) |
    #    fail(:citizen_not_verified | :person_not_found)
    def call(cpf:, cns:)
      return refuse(:invalid_request, "cns") if !cpf.nil? && !cns.nil?
      return refuse(:invalid_request, "cpf") if cpf.nil? && cns.nil?

      cpf.nil? ? by_cns(cns) : by_cpf(cpf)
    end

    def by_cpf(raw)
      cpf = raw.is_a?(String) ? CitizenIdentity::Cpf.normalize(raw) : nil
      return refuse(:invalid_cpf, "cpf") unless cpf

      patient = Patient.find_by(cpf: cpf)
      return Result.ok(patient: patient) if patient

      citizen = Pairs.of_cpf(cpf).order(:created_at, :id).first
      return Result.fail(:person_not_found) if citizen.nil? && !Citizen.not_erased.where(cpf: cpf).exists?
      return Result.fail(:citizen_not_verified) unless citizen

      resolved = Resolve.call(citizen)
      return Result.fail(:citizen_not_verified) if resolved.failure?

      Result.ok(patient: resolved.payload.fetch(:patient))
    end

    def by_cns(raw)
      cns = raw.is_a?(String) ? raw.delete(" ") : nil
      return refuse(:invalid_cns, "cns") unless cns && Professionals::Cns.valid?(cns)

      patient = Patient.find_by(cns: cns)
      patient ? Result.ok(patient: patient) : Result.fail(:person_not_found)
    end

    def refuse(reason, path) = Result.fail(reason, details: { path: path })
    private_class_method :by_cpf, :by_cns, :refuse
  end
end
