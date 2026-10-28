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
    # Sequência, não sorteio: hex(2) repetido no mesmo exemplo é nome de unidade duplicado.
    unit = over.delete(:unit) || create_unit("UBS Vigia #{@notification_unit_seq = (@notification_unit_seq || 0) + 1}")
    attrs = { patient: patient, disease: disease, origin: "manual", unit: unit, suspected_at: Time.current }.merge(over)
    attrs[:status] = status if status
    # Desvio 6: consulta e manual exigem quem grava.
    attrs[:by] = surveillance_officer! if attrs[:origin] != "safety_net" && !attrs.key?(:by)
    result = Surveillance::CreateNotification.call(**attrs)
    raise "notificação recusada: #{result.reason} #{result.details}" if result.failure?

    result.payload.fetch(:notification)
  end

  # Caso do painel (módulo 25, Task 16): paciente novo e notificação pelo
  # CreateNotification (manual, por um vigilante; safety_net quando
  # status: "possible"), com o bairro posto por update_columns (o trigger
  # de guarda deixa; o bairro vem do domicílio do paciente, que o cenário não
  # monta) e os demais estados pelo Transition / Dismiss.
  # Cobre: possible, notified, investigating, closed, entered (closed e
  # entered levam classification, confirmed por padrão) e dismissed. Status
  # desconhecido, ou classification fora de closed/entered, é ArgumentError:
  # nada de cair em notified em silêncio.
  PANEL_CASE_STEPS = { "possible" => [], "notified" => [], "dismissed" => [], "investigating" => %w[investigating],
                       "closed" => %w[investigating closed], "entered" => %w[investigating closed entered] }.freeze

  def panel_case!(neighborhood:, symptoms_on:, suspected_on:, status: "notified", classification: nil, disease_code: "dengue")
    raise ArgumentError, "unknown status: #{status.inspect}" unless PANEL_CASE_STEPS.key?(status)
    if classification && !%w[closed entered].include?(status)
      raise ArgumentError, "classification only with closed/entered, got #{status}"
    end

    @panel_seq = (@panel_seq || 1000) + 1
    safety_net = %w[possible dismissed].include?(status)
    officer = (@panel_officer ||= surveillance_officer!)
    notification = notification!(patient: surveillance_patient!(@panel_seq), disease_code: disease_code,
                                 origin: safety_net ? "safety_net" : "manual", suspected_at: suspected_on.in_time_zone,
                                 symptoms_on: symptoms_on, by: officer)
    notification.update_columns(neighborhood_id: neighborhood&.id)
    PANEL_CASE_STEPS.fetch(status).each do |to|
      extra = case to
              when "closed" then { classification: classification || "confirmed" }
              when "entered" then { official_number: "SINAN-#{@panel_seq}" }
              else {}
              end
      result = Surveillance::Transition.call(notification: notification, to: to, version: notification.reload.version, by: officer, **extra)
      raise "transição recusada: #{result.reason}" if result.failure?
    end
    if status == "dismissed"
      result = Surveillance::Dismiss.call(notification: notification, reason: "Não é caso", version: notification.version, by: officer)
      raise "descarte recusado: #{result.reason}" if result.failure?
    end
    notification.reload
  end
end

RSpec.configure { |c| c.include SurveillanceHelpers }
