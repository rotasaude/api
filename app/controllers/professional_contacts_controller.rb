# Contato do prescritor (ADR 0034; contrato §5): o próprio profissional lê e
# grava endereço (cifrado) e telefone. Atrás do prontuário, não do interruptor
# (a cidade prepara antes de ligar, como o CNPJ do 19c). Sem step-up.
class ProfessionalContactsController < ApplicationController
  include Authentication
  include AttendanceAccess
  include ClinicalRecordGate

  wrap_parameters false
  before_action :require_clinical_record!

  def show
    professional = Current.user.professional
    return render(json: { error: "not_found" }, status: :not_found) unless professional

    render json: payload(professional)
  end

  def update
    professional = Current.user.professional
    return render(json: { error: "not_found" }, status: :not_found) unless professional

    body = params.to_unsafe_h
    address, field = ClinicalDocuments::Address.normalize(body["address"])
    return render(json: { error: "invalid_address", field: field }, status: :unprocessable_entity) unless address

    phone = ClinicalDocuments::Address.phone(body["phone"])
    return render(json: { error: "invalid_phone" }, status: :unprocessable_entity) unless phone

    professional.update!(prescriber_address: address.to_json, phone: phone)
    render json: payload(professional)
  end

  private

  def payload(professional) = { address: professional.prescriber_address_data, phone: professional.phone }
end
