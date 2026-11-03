# Atendimentos marcados na data ainda sem viagem (contrato §4; §14 T5; plano,
# Desvio 6), para a central montar as viagens:
#  - pedido do 26a `scheduled` com `scheduled_at` na data (origin
#    "regulation"): destino = o município cadastrado (transport_destinations,
#    pelo `ibge_code`) do prestador do agendamento (`care_provider_id`);
#    `provider_name` = o NOME do prestador. O texto livre `schedule_place`
#    NUNCA é lido (pode trazer especialidade: "Clínica de Olhos");
#  - horário do 17 vivo (scheduled/confirmed) na data, só com `health_unit_id`
#    e só dessa unidade (origin "appointment"), do par validado do paciente;
#    destination_id nulo, provider_name = nome da unidade e address = endereço
#    dela (T32; nunca profissional nem tipo de atendimento);
#  - TFD authorized/scheduled/travelling com `appointment_at` na data (origin
#    "tfd"): destino do processo, prestador pelo nome quando houver.
# Fica de fora quem já está ativo (não retirado) numa viagem não cancelada
# com a mesma origem (chave estável origin + origin_id). `destination_id`
# filtra os itens que têm destino; os do 17 (sem destino) seguem só o
# `health_unit_id`. Ordem: horário, depois a chave.
# Nada de alvo, CID, justificativa, laudo nem observação: só a forma abaixo.
module Transport
  module ScheduledCare
    module_function

    # -> [ { "patient", "origin", "origin_id", "appointment_at", "destination" => { destination_id, provider_name, address } } ]
    def call(date:, destination_id: nil, health_unit_id: nil)
      range = date.in_time_zone.all_day
      items = regulation(range) + tfd(range)
      items += appointments(range, health_unit_id) if health_unit_id
      items = items.select { |item| item[:destination_id] == destination_id } if destination_id
      taken = taken_keys(items)
      items.reject { |item| taken.include?([ item[:origin], item[:origin_id] ]) }
           .sort_by { |item| [ item[:at], item[:origin], item[:origin_id] ] }
           .map { |item| render(item) }
    end

    def regulation(range)
      requests = RegulationRequest.where(status: AddPassenger::REGULATION_STATUSES, scheduled_at: range).includes(:patient, :care_provider)
      destinations = destinations_by_ibge(requests.filter_map { |r| r.care_provider&.ibge_code })
      requests.map do |request|
        provider = request.care_provider
        item("regulation", request.id, request.patient, request.scheduled_at,
             provider && destinations[provider.ibge_code], provider&.name)
      end
    end

    def tfd(range)
      TfdCase.where(status: AddPassenger::TFD_STATUSES, appointment_at: range).includes(:patient, :care_provider).map do |tfd_case|
        item("tfd", tfd_case.id, tfd_case.patient, tfd_case.appointment_at, tfd_case.transport_destination_id, tfd_case.care_provider&.name)
      end
    end

    def appointments(range, health_unit_id)
      rows = Appointment.where(status: Appointment::LIVE, health_unit_id: health_unit_id, scheduled_at: range).includes(:citizen, :health_unit)
      rows.filter_map do |appointment|
        patient = patient_of(appointment.citizen)
        unit = appointment.health_unit
        patient && item("appointment", appointment.id, patient, appointment.scheduled_at, nil, unit.name, unit_address(unit))
      end
    end

    # O paciente do par VALIDADO do horário (Patients::Pairs, ao contrário):
    # ligado a ele ou com o CPF dele. Par sem paciente fica de fora (a central
    # não cria paciente).
    def patient_of(citizen)
      return nil unless citizen && Patients::Pairs.base.exists?(id: citizen.id)

      citizen.patient || (citizen.cpf.present? ? Patient.find_by(cpf: citizen.cpf) : nil)
    end

    def destinations_by_ibge(codes)
      return {} if codes.empty?

      TransportDestination.where(ibge_code: codes.uniq).pluck(:ibge_code, :id).to_h
    end

    def taken_keys(items)
      columns = { "regulation" => :regulation_request_id, "appointment" => :appointment_id, "tfd" => :tfd_case_id }
      active = TransportTripPassenger.active.joins(:transport_trip).where.not(transport_trips: { status: "cancelled" })
      columns.flat_map do |origin, column|
        ids = items.filter_map { |item| item[:origin_id] if item[:origin] == origin }
        next [] if ids.empty?

        active.where(origin: origin, column => ids).pluck(column).map { |id| [ origin, id ] }
      end.to_set
    end

    # "Rua X, 100, sala 2" (só as partes preenchidas); sem nenhuma, nulo.
    def unit_address(unit) = [ unit.address_street, unit.address_number, unit.address_complement ].compact_blank.join(", ").presence

    def item(origin, id, patient, at, destination_id, provider_name, address = nil)
      { origin: origin, origin_id: id, patient: patient, at: at, destination_id: destination_id, provider_name: provider_name,
        address: address }
    end

    def render(item)
      { "patient" => Json.patient(item[:patient]), "origin" => item[:origin], "origin_id" => item[:origin_id],
        "appointment_at" => item[:at].in_time_zone.iso8601,
        "destination" => { "destination_id" => item[:destination_id], "provider_name" => item[:provider_name], "address" => item[:address] } }
    end
  end
end
