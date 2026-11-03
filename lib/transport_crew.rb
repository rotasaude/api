require "zlib"
require_relative "signature_crew"
require_relative "care_lines_crew"

# Semente de dev do módulo 30 (ADR 0048), para a prova no navegador. Dev é
# fictício mas imita o real: em Curitiba, `sanitary_transport` e `tfd` LIGADOS
# pelo mantenedor de dev; a "Central de transporte" (transporte@, papel
# transport_dispatcher), a "Comissão de TFD" (tfd@, tfd_committee), os
# motoristas "Davi Motorista" (CNH D válida) e "Caio Condutor" (CNH B que vence
# em 20 dias), todos com TOTP fixo (o usuário não tem campo de nome: o nome é o
# da persona); a van ABC1D23 (15 lugares, 1 cadeirante) e o carro BRA2E19 (4
# lugares); os destinos Curitiba (0 km), Ponta Grossa (117 km), Londrina (380
# km) e Araucária (27 km, metropolitana); a unidade "Secretaria Municipal de
# Saúde" (`health_management`, CNES de dev) como unidade de faturamento do TFD;
# uma série de hemodiálise seg/qua/sex para Ponta Grossa, já materializada nas
# próximas três semanas; e um TFD `authorized` para Londrina, com atendimento
# marcado em 7 dias. TUDO pelos comandos do app (SaveVehicle, SaveDriver,
# SaveDestination, SaveSettings, SaveSeries, MaterializeSeries, SaveCase,
# SubmitCase, SetAppointment e DecideCase).
#
# Pessoas: o Sebastião (hemodiálise) e o José (TFD, com a consulta finalizada da
# médica da UBS) do CareLinesCrew (só quem tem consulta tem paciente); o db:seed roda este crew depois dele.
# Idempotente: veículo, motorista, destino, unidade, série e processo são
# achados e retomados, nunca duplicados. Só e-mail, papel e otpauth na saída:
# nunca CPF nem nome de paciente.
class TransportCrew
  UNIT = CareLinesCrew::UNIT
  DEV_MAINTAINER = "dev@local".freeze
  EMAIL_DOMAIN = "dev".freeze # transporte@curitiba.dev (Valores fixados 6)
  MANAGEMENT_UNIT = "Secretaria Municipal de Saúde".freeze
  FEATURES = %w[sanitary_transport tfd].freeze
  DOCTOR_PREFIX = "profissional".freeze # a médica da UBS (ProfessionalCrew)
  SERIES_PATIENT = :sebastiao
  TFD_PATIENT = :jose
  BOARDING = "Praça Central".freeze
  TFD_REASON = "Tratamento sem oferta no município; autorizado na semente de dev.".freeze
  TFD_APPOINTMENT_IN_DAYS = 7

  STAFF = {
    dispatcher: { email_prefix: "transporte", role: "transport_dispatcher",
                  secret_env: "DEV_TRANSPORT_DISPATCHER_OTP_SECRET", default_secret: "TRANSPORTECENTRALSEMENTEDEVCWBAT" },
    committee: { email_prefix: "tfd", role: "tfd_committee",
                 secret_env: "DEV_TFD_COMMITTEE_OTP_SECRET", default_secret: "TFDCOMISSAOSEMENTEDEVCURITIBATFD" },
    davi: { email_prefix: "motorista", role: "driver",
            secret_env: "DEV_DRIVER_DAVI_OTP_SECRET", default_secret: "MOTORISTADAVISEMENTEDEVCWBATRANS" },
    caio: { email_prefix: "condutor", role: "driver",
            secret_env: "DEV_DRIVER_CAIO_OTP_SECRET", default_secret: "MOTORISTACAIOSEMENTEDEVCWBATRANS" }
  }.freeze

  VEHICLES = [
    { "plate" => "ABC1D23", "renavam" => "12345678901", "model" => "Mercedes-Benz Sprinter 415", "kind" => "van",
      "seats" => 15, "wheelchair_spots" => 1 },
    { "plate" => "BRA2E19", "renavam" => "10987654321", "model" => "Fiat Cronos", "kind" => "car",
      "seats" => 4, "wheelchair_spots" => 0 }
  ].freeze

  # Carteira de cada motorista: categoria e dias até vencer.
  LICENSES = {
    davi: { number: "10000000001", category: "D", expires_in_days: 3 * 365 },
    caio: { number: "10000000002", category: "B", expires_in_days: 20 }
  }.freeze

  DESTINATIONS = {
    curitiba: { "ibge_code" => "4106902", "name" => "Curitiba", "distance_km" => 0, "metropolitan" => false },
    ponta_grossa: { "ibge_code" => "4119905", "name" => "Ponta Grossa", "distance_km" => 117, "metropolitan" => false },
    londrina: { "ibge_code" => "4113700", "name" => "Londrina", "distance_km" => 380, "metropolitan" => false },
    araucaria: { "ibge_code" => "4101804", "name" => "Araucária", "distance_km" => 27, "metropolitan" => true }
  }.freeze

  # Hemodiálise seg/qua/sex (dias ISO 1, 3, 5) em Ponta Grossa.
  SERIES = { "weekdays" => [ 1, 3, 5 ], "appointment_time" => "08:30", "departure_time" => "05:30", "return_time" => "16:30",
             "boarding_label" => BOARDING, "provider_name" => "Clínica de Nefrologia" }.freeze

  # Laudo do TFD: o código é uma consulta especializada da SIGTAP de dev e o CID-10 vem
  # do recorte de dev que o RegulationCrew publica (M17, gonartrose).
  TFD_REPORT = { "sigtap_code" => "0301010072", "cid10" => "M17",
                 "justification" => "Gonartrose bilateral com limitação de marcha, sem ortopedia de joelho no município; avaliação especializada em Londrina.",
                 "companion_indicated" => false, "companion_reason" => nil, "transport_mode" => "fleet" }.freeze

  class << self
    def seed_current_city(slug:, ddd: nil, password: ENV.fetch(SignatureCrew::PASSWORD_ENV, "dev-password"))
      guard_environment!
      return off("fora") unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      unless maintainer
        warn "[seeds] transporte: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptores não ligados"
        return off("desligado (sem mantenedor #{DEV_MAINTAINER})")
      end

      city = City.find(Current.city.id)
      admin = User.find_by!(email_address: "admin@#{slug}.demo")
      doctor = User.find_by!(email_address: "#{DOCTOR_PREFIX}@#{slug}.demo")
      staff = staff!(slug, password)
      vehicles = VEHICLES.map { |spec| vehicle!(spec, admin) }
      drivers = LICENSES.to_h { |key, spec| [ key, driver!(staff.fetch(key), spec, admin) ] }
      destinations = DESTINATIONS.transform_values { |spec| destination!(spec, admin) }
      management = management_unit!(slug)
      settings!(management, admin)
      series = series!(slug, staff.fetch(:dispatcher), destinations.fetch(:ponta_grossa))
      materialized = materialize!(series)
      tfd = tfd_case!(slug, doctor, staff.fetch(:committee), destinations.fetch(:londrina))
      FEATURES.each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer) }

      { switch: Transport::Gate.usable?(city) && Tfd::Gate.usable?(city) ? "ligado (#{Transport::Gate::KEY} e #{Tfd::Gate::KEY})" : "ligado, não utilizável",
        vehicles: vehicles.size, drivers: drivers.size, destinations: destinations.size, series: TransportSeries.count,
        trips: TransportTrip.where(status: %w[planned confirmed]).count, materialized: materialized,
        tfd: TfdCase.group(:status).count.sort.to_h, tfd_status: tfd.status,
        users: staff.values.map { |user| { email: user.email_address, role: role_of(user), otpauth_uri: SignatureCrew.otpauth_uri(user) } } }
    end

    # As linhas que o db/seeds.rb imprime: só e-mail, papel e otpauth (nunca dado de paciente).
    def summary_lines(result, password:)
      lines = [ "[seeds] transporte sanitário #{result[:switch]}" \
                "#{"; #{result[:vehicles]} veículos; #{result[:drivers]} motoristas; #{result[:destinations]} destinos; " \
                   "#{result[:series]} série; #{result[:trips]} viagens; TFD #{counts(result[:tfd])}" if result[:vehicles].to_i.positive?}" ]
      lines + result[:users].map { |u| "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }
    end

    private

    def guard_environment!
      raise "semente do transporte: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def off(switch) = { switch: switch, vehicles: 0, drivers: 0, destinations: 0, series: 0, trips: 0, materialized: {}, tfd: {}, tfd_status: nil, users: [] }

    def counts(hash) = hash.empty? ? "nenhum" : hash.map { |status, count| "#{status} #{count}" }.join(", ")

    def check!(result, what)
      raise "semente do transporte: #{what} recusado (#{result.reason} #{result.details.slice(:path, :problems)})" if result.failure?

      result
    end

    # Mesma conta do RecordModeCrew, para o CNES ficar estável pela semente.
    def cnes_for(slug, name) = (Zlib.crc32("cnes:#{slug}:#{name}") % 9_000_000 + 1_000_000).to_s

    def role_of(user) = STAFF.values.find { |spec| user.email_address.start_with?("#{spec[:email_prefix]}@") }.fetch(:role)

    # --- equipe -----------------------------------------------------------------

    # { dispatcher:, committee:, davi:, caio: } => User, com o papel e o TOTP fixo.
    def staff!(slug, password)
      STAFF.to_h do |key, spec|
        user = User.find_or_initialize_by(email_address: "#{spec[:email_prefix]}@#{slug}.#{EMAIL_DOMAIN}")
        user.password = password
        user.save!
        Membership.find_or_create_by!(user: user, role: spec[:role]) { |membership| membership.granted_at = Time.current }
        SignatureCrew.ensure_totp(user, secret_env: spec[:secret_env], default_secret: spec[:default_secret])
        [ key, user.reload ]
      end
    end

    # --- frota, motoristas e destinos -------------------------------------------

    def vehicle!(spec, admin)
      existing = TransportVehicle.find_by(plate: spec.fetch("plate"))
      return existing if existing

      check!(Transport::SaveVehicle.call(attrs: spec, by: admin), "veículo").payload.fetch(:vehicle)
    end

    def driver!(user, spec, admin)
      existing = TransportDriver.find_by(user_id: user.id)
      return existing if existing

      attrs = { "user_id" => user.id, "license_number" => spec.fetch(:number), "license_category" => spec.fetch(:category),
                "license_expires_on" => (Time.zone.today + spec.fetch(:expires_in_days)).iso8601 }
      check!(Transport::SaveDriver.call(attrs: attrs, by: admin), "motorista").payload.fetch(:driver)
    end

    def destination!(spec, admin)
      existing = TransportDestination.find_by(ibge_code: spec.fetch("ibge_code"))
      return existing if existing

      check!(Transport::SaveDestination.call(attrs: spec, by: admin), "destino").payload.fetch(:destination)
    end

    # --- unidade de faturamento e parâmetros ------------------------------------

    def management_unit!(slug)
      HealthUnit.find_or_create_by!(name: MANAGEMENT_UNIT) do |unit|
        unit.kind = "health_management"
        unit.cnes = cnes_for(slug, MANAGEMENT_UNIT)
      end
    end

    def settings!(unit, admin)
      return if Transport::Settings.current.tfd_billing_health_unit_id == unit.id

      check!(Transport::SaveSettings.call(attrs: { "tfd_billing_health_unit_id" => unit.id }, by: admin), "parâmetros")
    end

    # --- série de hemodiálise ----------------------------------------------------

    def patient_of(slug, key)
      patient = Patient.find_by(cpf: CareLinesCrew.cpf_for(slug, key))
      raise "semente do transporte: #{key} ausente — rode o CareLinesCrew (db:seed inteiro) antes" unless patient

      patient
    end

    def series!(slug, dispatcher, destination)
      patient = patient_of(slug, SERIES_PATIENT)
      existing = TransportSeries.find_by(patient_id: patient.id, transport_destination_id: destination.id)
      return existing if existing

      attrs = SERIES.merge("patient_id" => patient.id, "destination_id" => destination.id, "starts_on" => Time.zone.today.iso8601)
      check!(Transport::SaveSeries.call(attrs: attrs, by: dispatcher), "série").payload.fetch(:series)
    end

    # O que o job diário faria, só para esta série (as viagens das próximas
    # três semanas); rodar de novo não duplica: o paciente já está na viagem.
    def materialize!(series)
      TransportSeries.transaction do
        series.lock!
        Transport::MaterializeSeries.call(series: series, today: Time.zone.today)
      end
    end

    # --- TFD ----------------------------------------------------------------------

    # O laudo da médica sobre a consulta finalizada do José: rascunho → envio →
    # atendimento marcado → autorizado, retomado do ponto em que está.
    def tfd_case!(slug, doctor, committee, destination)
      patient = patient_of(slug, TFD_PATIENT)
      tfd = TfdCase.find_by(patient_id: patient.id, transport_destination_id: destination.id) || draft!(patient, doctor, destination)
      tfd = check!(Tfd::SubmitCase.call(tfd_case: tfd, by: doctor), "envio do laudo").payload.fetch(:tfd_case) if %w[draft returned].include?(tfd.status)
      return tfd unless tfd.status == "submitted"

      unless tfd.appointment_at&.future?
        at = (Time.zone.today + TFD_APPOINTMENT_IN_DAYS).in_time_zone.change(hour: 9).iso8601
        tfd = check!(Tfd::SetAppointment.call(tfd_case: tfd, appointment_at: at, by: committee), "atendimento marcado").payload.fetch(:tfd_case)
      end
      check!(Tfd::DecideCase.call(tfd_case: tfd, decision: "authorize", reason: TFD_REASON, by: committee), "autorização").payload.fetch(:tfd_case)
    end

    def draft!(patient, doctor, destination)
      consultation = patient.consultations.finalized_consultations.where(author_user_id: doctor.id).order(:created_at).first
      raise "semente do transporte: sem consulta finalizada da médica para o TFD — rode o CareLinesCrew (db:seed inteiro) antes" unless consultation

      attrs = { "patient_id" => patient.id, "consultation_id" => consultation.id, "destination_id" => destination.id, "report" => TFD_REPORT }
      check!(Tfd::SaveCase.call(attrs: attrs, by: doctor), "laudo").payload.fetch(:tfd_case)
    end
  end
end
