# Módulo 25 (ADR 0043): cidade com o prontuário e a vigilância ligados, a
# lista nacional carregada, o vigilante e pacientes com par validado.
# Cenário de teste: os caminhos reais são Surveillance::DiseaseList::Load,
# Patients::Resolve e Surveillance::CreateNotification.
module SurveillanceHelpers
  # consultation: false liga só a vigilância (prontuário desligado: a consulta
  # e a ficha não estão utilizáveis; o resto do módulo funciona).
  def surveillance_city!(consultation: true)
    city = clinical_city!(enabled: consultation)
    cid10_release!
    sigtap_release!
    ciap2_release!(ScreeningHelpers::CIAP2.merge("A70" => "Tuberculose", "B90" => "Infecção por HIV/SIDA"))
    Surveillance::DiseaseList::Load.call
    Platform::Features.set!(city: city, key: "surveillance", enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    city
  end

  def surveillance_officer!(email = "vigilancia-#{SecureRandom.hex(3)}@cidade.gov.br") = staff_with(email, "surveillance")

  # Paciente (caminho real: par validado + Patients::Resolve); n dá CPF e telefone únicos.
  def surveillance_patient!(n, **over) = exam_patient!(n, **over).first

  # Notificação pelo comando da Task 7 (Surveillance::CreateNotification),
  # avaliado só na chamada: o comando não existe antes da Task 7, e o primeiro
  # uso é da Task 11. status: ajusta o estado inicial quando difere do que a
  # origem produz (safety_net nasce possible; os outros, notified).
  def notification!(patient:, disease_code: "dengue", status: nil, **over)
    disease = Surveillance::Diseases.find(disease_code) || raise("doença desconhecida: #{disease_code}")
    unit = over.delete(:unit) || create_unit("UBS Vigia #{SecureRandom.hex(2)}")
    attrs = { patient: patient, disease: disease, origin: "manual", unit: unit, suspected_at: Time.current }.merge(over)
    attrs[:status] = status if status
    # Desvio 6: consulta e manual exigem quem grava.
    attrs[:by] = surveillance_officer! if attrs[:origin] != "safety_net" && !attrs.key?(:by)
    result = Surveillance::CreateNotification.call(**attrs)
    raise "notificação recusada: #{result.reason} #{result.details}" if result.failure?

    result.payload.fetch(:notification)
  end
end

RSpec.configure { |c| c.include SurveillanceHelpers }
