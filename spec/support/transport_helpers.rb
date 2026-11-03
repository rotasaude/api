# Módulo 30 (ADR 0048): cidade do transporte sanitário (e do TFD), SIGTAP do
# 08.03.01 (ajudas de custo), central, comissão, motorista com CNH, veículo,
# destino, viagem e passageiro gravados direto no banco (os caminhos reais são
# os comandos das Tasks 3–5), paciente com par validado e telefone, processo de
# TFD (gravação direta até o Tfd::SaveCase da Task 9) e a unidade de gestão.
# Tudo avaliado só na chamada.
module TransportHelpers
  # Os 10 códigos do 08.03.01 (config/tfd/sigtap_codes.yml, Task 2) com o
  # valor SA de teste: código => [nome, centavos].
  TFD_SIGTAP = {
    "0803010010" => [ "AJUDA DE CUSTO PARA ALIMENTACAO/PERNOITE DE PACIENTE", 1000 ],
    "0803010028" => [ "AJUDA DE CUSTO PARA ALIMENTACAO DE PACIENTE SEM PERNOITE", 840 ],
    "0803010044" => [ "AJUDA DE CUSTO PARA ALIMENTACAO/PERNOITE DE ACOMPANHANTE", 2475 ],
    "0803010052" => [ "AJUDA DE CUSTO PARA ALIMENTACAO DE ACOMPANHANTE SEM PERNOITE", 1000 ],
    "0803010079" => [ "UNIDADE DE REMUNERACAO P/ DESLOCAMENTO DE ACOMPANHANTE POR TRANSPORTE AEREO (CADA 200 MILHAS)", 1000 ],
    "0803010087" => [ "UNIDADE DE REMUNERACAO P/ DESLOCAMENTO DE PACIENTE POR TRANSPORTE AEREO (CADA 200 MILHAS)", 1000 ],
    "0803010095" => [ "UNIDADE DE REMUNERACAO P/ DESLOCAMENTO DE ACOMPANHANTE POR TRANSPORTE FLUVIAL (CADA 27 MILHAS NAUTICAS)", 1000 ],
    "0803010109" => [ "UNIDADE DE REMUNERACAO P/ DESLOCAMENTO DE ACOMPANHANTE POR TRANSPORTE TERRESTRE (CADA 50 KM)", 1000 ],
    "0803010117" => [ "UNIDADE DE REMUNERACAO P/ DESLOCAMENTO DE PACIENTE POR TRANSPORTE FLUVIAL (CADA 27 MILHAS NAUTICAS)", 1000 ],
    "0803010125" => [ "UNIDADE DE REMUNERACAO P/ DESLOCAMENTO DE PACIENTE POR TRANSPORTE TERRESTRE (CADA 50 KM)", 495 ]
  }.freeze
  TFD_INSTRUMENT = "02".freeze
  TFD_CBO = "225125".freeze

  # Laudo válido (Desvio 10): o `report:` de tfd_case! é mesclado por cima.
  TFD_REPORT = { "sigtap_code" => "0301010072", "cid10" => "N185",
                 "justification" => "Doença renal crônica estágio 5 sem serviço de nefrologia no município",
                 "companion_indicated" => true, "companion_reason" => "Paciente com limitação de mobilidade",
                 "transport_mode" => "fleet" }.freeze

  # Prontuário (clinical_city!) com `sanitary_transport` e, com tfd: true,
  # `tfd`. Com billing: true, a cidade do faturamento (billing_city!), com a
  # SIGTAP do TFD criada ANTES (a SIGTAP ativa é imutável). Os parâmetros (a linha que a migração insere
  # e o dump não leva) entram aqui.
  def transport_city!(tfd: false, billing: false)
    tfd_sigtap! if billing || tfd
    city = billing ? billing_city! : clinical_city!
    maintainer = ledi_maintainer!
    keys = [ "sanitary_transport", ("tfd" if tfd) ].compact
    keys.each do |key|
      Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer)
    end
    TransportSetting.ensure_defaults!
    CityCatalog.reset_cache!
    city
  end

  # As releases SIGTAP da competência do dia e da anterior (as do
  # billing_sigtap!) com tudo do faturamento e os 10 códigos do 08.03.01
  # (valor SA, instrumento 02, CBO 225125). Chame antes de billing_city!/
  # exam_city!: depois de ativa, a release não muda.
  def tfd_sigtap!(competences = [ Time.zone.today.strftime("%Y%m"), Time.zone.today.prev_month.strftime("%Y%m") ])
    Array(competences).map do |competence|
      existing = TerminologyRelease.active.find_by(kind: "sigtap", version: competence)
      if existing
        raise "tfd_sigtap! depois de billing_city!/exam_city!: chame antes" unless
          SigtapProcedure.exists?(release_id: existing.id, code: TFD_SIGTAP.keys.first)

        next existing
      end
      release = TerminologyRelease.create!(kind: "sigtap", version: competence, source_sha256: "c" * 64, imported_by: "rspec",
                                           imported_at: Time.current, status: "importing")
      ClinicalRecordHelpers::SIGTAP.transform_values { |name| [ name, nil, nil, nil ] }.merge(BillingHelpers::PROCEDURES)
                                   .each do |code, (name, sex, min, max)|
        SigtapProcedure.create!(release: release, code: code, name: name, sex: sex, age_min_months: min, age_max_months: max)
      end
      TFD_SIGTAP.each { |code, (name, cents)| SigtapProcedure.create!(release: release, code: code, name: name, amount_sa_cents: cents) }
      instruments = BillingHelpers::INSTRUMENTS.merge(TFD_SIGTAP.keys.index_with { [ TFD_INSTRUMENT ] })
      instruments.each do |code, list|
        list.each do |reg|
          SigtapProcedureInstrument.create!(release: release, procedure_code: code, instrument_code: reg,
                                            instrument_name: BillingHelpers::REGISTRIES.fetch(reg))
        end
      end
      BillingHelpers::CBOS.merge(TFD_SIGTAP.keys.index_with { [ TFD_CBO ] }).each do |code, list|
        list.each { |cbo| SigtapProcedureCbo.create!(release: release, procedure_code: code, cbo_code: cbo) }
      end
      BillingHelpers::CIDS.each do |code, list|
        list.each { |cid| SigtapProcedureCid.create!(release: release, procedure_code: code, cid_code: cid, principal: true) }
      end
      release.update!(status: "active", activated_at: Time.current)
      release
    end
  end

  def transport_admin!
    @transport_admin ||= step_up_enrolled!(staff_with("admin-transporte-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
  end

  def dispatcher! = (@dispatcher ||= staff_with("central-#{SecureRandom.hex(3)}@cidade.gov.br", "transport_dispatcher"))
  def committee! = staff_with("comissao-tfd-#{SecureRandom.hex(3)}@cidade.gov.br", "tfd_committee")

  # Usuário `driver` com o cadastro de motorista (CNH de 11 dígitos aleatória).
  def driver_user!(category: "D", expires_on: Date.current + 365)
    user = staff_with("motorista-#{SecureRandom.hex(3)}@cidade.gov.br", "driver")
    TransportDriver.create!(user: user, license_number: format("%011d", SecureRandom.random_number(10**11)),
                            license_category: category, license_expires_on: expires_on, updated_by_user: transport_admin!)
    user.reload
  end

  # Placa Mercosul e RENAVAM aleatórios (únicos por chamada).
  def vehicle!(seats: 15, wheelchair_spots: 1, kind: "van")
    letters = Array.new(3) { ("A".."Z").to_a.sample }.join
    plate = "#{letters}#{rand(10)}#{('A'..'Z').to_a.sample}#{format('%02d', rand(100))}"
    TransportVehicle.create!(plate: plate, renavam: format("%011d", SecureRandom.random_number(10**11)), model: "Sprinter 415",
                             kind: kind, seats: seats, wheelchair_spots: wheelchair_spots, updated_by_user: transport_admin!)
  end

  # Um destino por IBGE (único): a segunda chamada com o mesmo IBGE o reaproveita.
  def destination!(name: "Ponta Grossa", ibge: "4119905", km: 117, metropolitan: false)
    TransportDestination.find_by(ibge_code: ibge) ||
      TransportDestination.create!(ibge_code: ibge, name: name, distance_km: km, metropolitan: metropolitan,
                                   updated_by_user: transport_admin!)
  end

  # Viagem gravada direto (o caminho real é o Transport::SaveTrip da Task 4),
  # com a parada de embarque "Praça Central" e a de destino. Horas locais da
  # cidade; `back` antes de `departure` é a volta no dia seguinte.
  def trip!(date: Date.current + 1, departure: "07:00", back: "18:00", vehicle: nil, driver: nil, status: "planned",
            destination: destination!)
    departure_at = Time.zone.parse("#{date.iso8601} #{departure}")
    return_at = Time.zone.parse("#{date.iso8601} #{back}")
    return_at += 1.day if return_at <= departure_at
    ApplicationRecord.transaction(requires_new: true) do
      trip = TransportTrip.create!(departure_at: departure_at, return_at: return_at, transport_vehicle: vehicle, transport_driver: driver,
                                   status: status, created_by_user: dispatcher!,
                                   confirmed_at: (Time.current if %w[confirmed in_progress done].include?(status)))
      trip.transport_trip_stops.create!(position: 1, kind: "boarding", label: "Praça Central")
      trip.transport_trip_stops.create!(position: 2, kind: "destination", transport_destination: destination, label: destination.name)
      trip
    end
  end

  # Passageiro gravado direto (o caminho real é o Transport::AddPassenger da
  # Task 5): exceção `legacy_patient`, embarque na primeira parada.
  def passenger!(trip, patient: transport_patient!, **over)
    boarding = trip.transport_trip_stops.find_by!(kind: "boarding")
    destination = trip.transport_trip_stops.find_by!(kind: "destination").transport_destination
    TransportTripPassenger.create!({ transport_trip: trip, patient: patient, transport_trip_stop: boarding,
                                     transport_destination: destination, origin: "exception", exception_reason: "legacy_patient",
                                     added_by_user: dispatcher! }.merge(over))
  end

  # Paciente com par validado e telefone (o caminho do exam_patient!), com a
  # data de nascimento pedida (a regra do acompanhante olha a idade).
  def transport_patient!(birth_date: "1980-05-10")
    patient = exam_patient!(exam_seq!).first
    patient.update!(birth_date: birth_date)
    patient
  end

  # Processo de TFD gravado direto (o caminho real é o Tfd::SaveCase da Task
  # 9): consulta iniciada do mesmo paciente pelo médico autor (CBO 225125) e o
  # laudo válido mesclado com `report:`; fora de `draft`, `submitted_at`.
  def tfd_case!(status: "draft", patient: transport_patient!, destination: destination!(name: "Londrina", ibge: "4113700", km: 380),
                report: {})
    unit = create_unit("UBS TFD #{SecureRandom.hex(2)}")
    doctor = doctor!(unit)
    citizen = Patients::Pairs.of(patient).first or raise "tfd_case!: paciente sem par validado"
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    TfdCase.create!(patient: patient, consultation: consultation, requester_user: doctor, requester_cbo: TFD_CBO,
                    report: TFD_REPORT.merge(report.transform_keys(&:to_s)), transport_destination: destination, status: status,
                    submitted_at: (Time.current unless status == "draft"))
  end

  # A secretaria (unidade de gestão, unidade de faturamento do TFD).
  def health_management_unit!(cnes: billing_cnes)
    HealthUnit.create!(name: "Secretaria Municipal de Saúde #{SecureRandom.hex(2)}", kind: "health_management", cnes: cnes)
  end
end

RSpec.configure { |c| c.include TransportHelpers }
