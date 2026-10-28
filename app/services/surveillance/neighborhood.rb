# Bairro congelado na notificação (módulo 25, Desvio 7): o da última versão do
# domicílio do cadastro individual ativo (24a) → o do par validado mais
# recente → nil ("não informado"). Só o id; nunca em log.
module Surveillance
  module Neighborhood
    module_function

    def for(patient) = from_household(patient) || latest_pair(patient)&.neighborhood_id

    # O par validado mais recente: o mesmo critério do Billing::PatientContact
    # (telefone da ficha), para bairro e telefone saírem do mesmo par.
    def latest_pair(patient)
      Citizen.not_erased.verification_level_verified.where(patient_id: patient.id).order(updated_at: :desc, id: :desc).first
    end

    def from_household(patient)
      household = IndividualRegistration.active_registrations.find_by(patient_id: patient.id)&.household
      household&.latest_version&.neighborhood_id
    end
    private_class_method :from_household
  end
end
