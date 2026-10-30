# POST /pharmacy/person_lookup (contrato §13 H2, P3): a pessoa pelo CPF OU pelo
# CNS, só no corpo (query → 422 invalid_request), para quem vai dispensar uma
# receita externa. A forma e as recusas do Surveillance::PersonLookupsController
# (`invalid_cpf`/`invalid_cns` 422, `citizen_not_verified` 409,
# `person_not_found` 404), MAS aqui o par validado sem paciente vira paciente
# (Patients::Resolve, como o patient_lookup do 21a e o 24a): a receita externa
# precisa de `patient_id`. Os dois ou nenhum → 422 invalid_request.
#
#  - CPF: o paciente do CPF; senão o par validado do CPF (cria o paciente);
#    par só declarado → 409 citizen_not_verified; ninguém → 404.
#  - CNS: só pacientes (o CNS do par é cifrado sem chave de busca): paciente
#    digitado sem CPF; ninguém → 404 person_not_found.
#
# → `{ patient_id, display_name, has_cpf, cns_masked }` (nunca CPF nem CNS
# inteiros). Trilha por pessoa mostrada (nenhuma quando não achou). 30 por
# minuto por usuário. `pharmacist` ou `pharmacy_assistant` de algum local `unit`.
module Pharmacy
  class PersonLookupsController < BaseController
    rate_limit to: 30, within: 1.minute, only: :create, name: "pharmacy_person_lookup", store: RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def create
      return forbid unless dispenser_anywhere?
      return unless query_only!

      cpf = body_param("cpf")
      cns = body_param("cns")
      return render_refusal("cns") if !cpf.nil? && !cns.nil?
      return render_refusal("cpf") if cpf.nil? && cns.nil?

      patient = cpf.nil? ? patient_by_cns(cns) : patient_by_cpf(cpf)
      return unless patient

      Trail.person_viewed!(user: Current.user, patient_id: patient.id)
      render json: Json.patient_lookup(patient)
    end

    private

    # Patient | nil (já respondeu).
    def patient_by_cpf(raw)
      cpf = raw.is_a?(String) ? CitizenIdentity::Cpf.normalize(raw) : nil
      return refuse_lookup("cpf", "invalid_cpf") unless cpf

      patient = Patient.find_by(cpf: cpf)
      return patient if patient

      citizen = Patients::Pairs.of_cpf(cpf).order(:created_at, :id).first
      return refuse_status("person_not_found", :not_found) if citizen.nil? && !Citizen.not_erased.where(cpf: cpf).exists?
      return refuse_status("citizen_not_verified", :conflict) unless citizen

      resolved = Patients::Resolve.call(citizen)
      return refuse_status("citizen_not_verified", :conflict) if resolved.failure?

      resolved.payload.fetch(:patient)
    end

    def patient_by_cns(raw)
      cns = raw.is_a?(String) ? raw.delete(" ") : nil
      return refuse_lookup("cns", "invalid_cns") unless cns && Professionals::Cns.valid?(cns)

      patient = Patient.find_by(cns: cns)
      render_error("person_not_found", :not_found) unless patient
      patient
    end

    def refuse_status(error, status)
      render_error(error, status)
      nil
    end

    def refuse_lookup(path, error)
      render_refusal(path, error)
      nil
    end
  end
end
