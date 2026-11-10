# Módulo 32b (ADR 0050; contrato §4): a observação da UPA nos specs. Leito
# gravado direto (o cadastro é a Task 5), o encontro em atendimento pela via
# real (chegada, classificação e chamada do médico) e a entrada no leito pelo
# Urgency::StartObservation. A enfermagem e o médico de cada UPA são os
# mesmos em todas as chamadas do exemplo.
module UrgencyObservationHelpers
  def urgency_bed!(unit, label: "OBS #{SecureRandom.hex(2)}", active: true)
    UrgencyBed.create!(health_unit: unit, label: label, active: active, updated_by_user: urgency_admin!)
  end

  def observation_nurse!(unit) = ((@observation_nurses ||= {})[unit.id] ||= upa_nurse!(unit))
  def observation_doctor!(unit) = ((@observation_doctors ||= {})[unit.id] ||= upa_doctor!(unit))

  # Chegada, classificação (verde) e chamada do médico: o encontro em `in_care`.
  def in_care_encounter!(unit, patient: nil)
    encounter = arrived!(unit, patient: patient || urgency_patient!(urgency_seq!))
    classified!(encounter, color: "green", by: observation_nurse!(unit))
    called!(encounter, by: observation_doctor!(unit))
  end

  # Entrada (ou troca) de leito pela via real. Devolve a estadia aberta.
  def observed!(encounter, bed:, by: observation_doctor!(bed.health_unit), now: Time.current)
    result = Urgency::StartObservation.call(encounter: encounter, bed_id: bed.id, by: by, now: now)
    raise "observed! recusado: #{result.reason} #{result.details}" if result.failure?

    result.payload.fetch(:stay)
  end
end

RSpec.configure { |c| c.include UrgencyObservationHelpers }
