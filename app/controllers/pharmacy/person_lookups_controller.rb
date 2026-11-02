# POST /pharmacy/person_lookup (contrato §13 H2, P3): a pessoa pelo CPF OU pelo
# CNS, só no corpo (query → 422 invalid_request), para quem vai dispensar uma
# receita externa. A forma e as recusas do Surveillance::PersonLookupsController
# (`invalid_cpf`/`invalid_cns` 422, `citizen_not_verified` 409,
# `person_not_found` 404), MAS aqui o par validado sem paciente vira paciente
# (Patients::Resolve, como o patient_lookup do 21a e o 24a): a receita externa
# precisa de `patient_id`. Os dois ou nenhum → 422 invalid_request. A regra
# mora em Patients::LookupByIdentifier (a sala de vacina usa a mesma).
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

      found = Patients::LookupByIdentifier.call(cpf: body_param("cpf"), cns: body_param("cns"))
      return render_lookup_failure(found) if found.failure?

      patient = found.payload.fetch(:patient)
      Trail.person_viewed!(user: Current.user, patient_id: patient.id)
      render json: Json.patient_lookup(patient)
    end

    private

    # Recusa de campo → 422 com problems; par só declarado → 409; ninguém → 404.
    def render_lookup_failure(result)
      case result.reason
      when :citizen_not_verified then render_error("citizen_not_verified", :conflict)
      when :person_not_found then render_error("person_not_found", :not_found)
      else render_refusal(result.details.fetch(:path), result.reason)
      end
    end
  end
end
