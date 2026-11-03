require "zlib"
require "openssl"
require "base64"
require_relative "signature_crew"
require_relative "care_lines_crew"
require_relative "record_mode_crew"

# Semente de dev do módulo 29 (ADR 0047), para a prova no navegador. Dev é
# fictício mas imita o real: em Curitiba, `vaccination`, `rnds_immunization` e
# `rnds_mock` LIGADOS pelo mantenedor de dev; a "Sala de vacina UBS Jardim das
# Flores" na UBS Jardim das Flores (com o CNES da unidade); a técnica "Vera
# Vacinadora" (CBO 322205, vacinadora) e a enfermeira "Rita Responsável" (CBO
# 223505, responsável da sala), ambas com perfil COREN, vínculo com a UBS e TOTP
# fixo; o CNS da Vera no retrato mais recente do CNES (sem ele a NT 115 barra
# o envio); a rede de frio municipal ("Rede de frio municipal", com o almoxarife
# do 27a); 4 lotes (penta 42, VIP 22, SCR 24, BCG 15) abertos na rede de frio
# e metade transferida para a sala; a "Geladeira 1" da sala; o go-live um ano
# atrás; a credencial `rnds` com um certificado de teste (PFX autoassinado,
# `CN=Rota Saude Simulado`) que o fake-rnds aceita sem conferir (não há mTLS no
# simulado), para a prova no navegador não travar na credencial; e uma dose de
# penta D1 numa criança de dois meses, nascida depois do go-live (caderneta
# conferida), na fila do envio à RNDS simulada. TUDO pelos comandos do app
# (SaveRoom, LinkRoomStaff, CreateColdChainCentral, SaveSettings, SaveEquipment,
# RecordEntry, SendTransfer, ReceiveTransfer e RecordImmunization).
#
# O catálogo de imunobiológicos segue com `review: true` em dev, e o requisito
# `vaccination_catalog_reviewed` só vale fora de dev, test e staging; então os
# interruptores ficam utilizáveis em dev. O `fake-rnds` fala http na 8094
# (`FAKE_RNDS_URL`); sem ele a fila só espera.
#
# Idempotente: sala, equipe, rede de frio, lotes (abertura por local e
# produto), transferência (uma só da rede de frio para a sala), equipamento,
# credencial (a existente fica como está), paciente e dose são achados e
# retomados, nunca duplicados. Só e-mail, papel e otpauth na saída: nunca
# dado de paciente.
class VaccinationCrew
  UNIT = CareLinesCrew::UNIT
  DEV_MAINTAINER = "dev@local".freeze
  ROOM = "Sala de vacina #{UNIT}".freeze
  CENTRAL = "Rede de frio municipal".freeze
  EQUIPMENT = "Geladeira 1".freeze
  KEEPER_PREFIX = "almoxarifado".freeze # o almoxarife do 27a (PharmacyCrew)
  FEATURES = %w[vaccination rnds_immunization rnds_mock].freeze
  CERTIFICATE_CN = "Rota Saude Simulado".freeze
  CERTIFICATE_PASSWORD = "rota-simulado".freeze
  CERTIFICATE_YEARS = 10

  STAFF = {
    vaccinator: { email_prefix: "vacinadora", name: "Vera Vacinadora", cbo: "322205", role: "vaccinator",
                  secret_env: "DEV_VACCINATOR_OTP_SECRET", default_secret: "VACINADORASEMENTEDEVCWBAVACINAS2" },
    lead: { email_prefix: "vacina.responsavel", name: "Rita Responsável", cbo: "223505", role: "room_lead",
            secret_env: "DEV_ROOM_LEAD_OTP_SECRET", default_secret: "RESPONSAVELSALAVACINASEMENTEDEVC" }
  }.freeze

  # Os 4 lotes: o que entra na rede de frio (frascos × doses por frasco do
  # catálogo) e quantas doses seguem para a sala (múltiplo do frasco).
  LOTS = [
    { code: "42", key: "serum", lot: "PE2611-A", days: 300, vials: 60, to_room: "30" },        # penta, unidose
    { code: "22", key: "sanofi", lot: "VP2611-A", days: 240, vials: 20, to_room: "100" },      # VIP, 10 doses
    { code: "24", key: "biomanguinhos", lot: "SC2611-A", days: 270, vials: 10, to_room: "50" }, # SCR, 10 doses
    { code: "15", key: "serum", lot: "BC2611-A", days: 200, vials: 10, to_room: "50" }         # BCG, 10 doses
  ].freeze

  # A criança do exemplo: dois meses e um dia de vida, penta D1 (estratégia
  # rotina, grupo criança, via intramuscular, vasto lateral da coxa direita).
  CHILD = { name: "Davi Lucas Ferreira Nunes", mother: "Patrícia Ferreira Nunes", sex: "male", age_days: 61 }.freeze
  DOSE = { "immunobiological_code" => "42", "dose_code" => "1", "strategy" => "1", "care_group" => "121", "route" => "3", "site" => "18" }.freeze

  class << self
    def seed_current_city(slug:, ddd: nil, password: ENV.fetch(SignatureCrew::PASSWORD_ENV, "dev-password"))
      guard_environment!
      return off("fora") unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      unless maintainer
        warn "[seeds] sala de vacina: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptores não ligados"
        return off("desligado (sem mantenedor #{DEV_MAINTAINER})")
      end
      keeper = User.find_by(email_address: "#{KEEPER_PREFIX}@#{slug}.demo")
      raise "semente da sala de vacina: sem o almoxarife do 27a — rode o db:seed inteiro (PharmacyCrew) antes" unless keeper

      city = City.find(Current.city.id)
      admin = User.find_by!(email_address: "admin@#{slug}.demo")
      unit = HealthUnit.find_by!(name: UNIT)
      unit.update!(cnes: cnes_for(slug, UNIT)) if unit.cnes.blank?

      VaccinationSetting.ensure_defaults!
      go_live!(admin)
      room = room!(admin, unit)
      staff = staff!(slug, password, admin, unit, room)
      skipped = []
      skipped << "o retrato do CNES não existe: sem o IBGE da cidade não há onde pôr o CNS da vacinadora" unless cnes_bond!(unit, staff.fetch(:vaccinator))
      central = central!(admin, keeper)
      stock!(central, room, keeper: keeper, lead: staff.fetch(:lead))
      equipment!(room)
      credential!(admin, unit)
      FEATURES.each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer) }
      dose!(room, staff.fetch(:vaccinator), slug)

      { switch: Vaccination::Gate.usable?(city) ? "ligado (#{Vaccination::Gate::KEY})" : "ligado, não utilizável",
        rnds: Rnds::Gate.usable?(city) && Rnds::Mock.on?(city) ? "RNDS simulada utilizável" : "RNDS simulada não utilizável",
        rooms: [ room.name ], locations: [ central.name ], lots: StockLot.where(item_kind: "immunobiological").count,
        doses: Immunization.count, outbox: RndsOutboxEntry.group(:status).count.sort.to_h, skipped: skipped,
        users: staff.values.map { |user| { email: user.email_address, role: role_of(user), otpauth_uri: SignatureCrew.otpauth_uri(user) } } }
    end

    # As linhas que o db/seeds.rb imprime: só e-mail, papel e otpauth (nunca dado de paciente).
    def summary_lines(result, password:)
      lines = [ "[seeds] sala de vacina #{result[:switch]}" \
                "#{"; #{result[:rnds]}; sala #{result[:rooms].join(', ')}; rede de frio #{result[:locations].join(', ')}; " \
                   "#{result[:lots]} lotes; #{result[:doses]} doses; envio #{counts(result[:outbox])}" if result[:rooms]&.any?}" ]
      lines += Array(result[:skipped]).map { |why| "[seeds]               pulado: #{why}" }
      lines + result[:users].map { |u| "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }
    end

    private

    def guard_environment!
      raise "semente da sala de vacina: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def off(switch) = { switch: switch, rnds: nil, rooms: [], locations: [], lots: 0, doses: 0, outbox: {}, skipped: [], users: [] }

    def counts(hash) = hash.empty? ? "nenhum" : hash.map { |status, count| "#{status} #{count}" }.join(", ")

    def check!(result, what)
      raise "semente da sala de vacina: #{what} recusado (#{result.reason} #{result.details.slice(:path, :problems)})" if result.failure?

      result
    end

    # Mesma conta do RecordModeCrew, para o CNES da unidade bater com o do retrato.
    def cnes_for(slug, name) = (Zlib.crc32("cnes:#{slug}:#{name}") % 9_000_000 + 1_000_000).to_s

    def role_of(user) = STAFF.values.find { |spec| user.email_address.start_with?("#{spec[:email_prefix]}@") }.fetch(:role)

    # --- sala, equipe e parâmetros -------------------------------------------

    # Só quando ainda não há data: o que o usuário gravar fica.
    def go_live!(admin)
      return if VaccinationSetting.current.go_live_on

      check!(Vaccination::SaveSettings.call(attrs: { "go_live_on" => (Time.zone.today - 1.year).iso8601 }, by: admin), "go-live")
    end

    def room!(admin, unit)
      existing = VaccineRoom.find_by(health_unit_id: unit.id)
      return existing if existing

      saved = Vaccination::SaveRoom.call(attrs: { "name" => ROOM, "health_unit_id" => unit.id }, by: admin)
      check!(saved, "sala de vacina").payload.fetch(:room)
    end

    # { vaccinator:, lead: } => User, já com perfil, vínculo com a UBS e vínculo com a sala.
    def staff!(slug, password, admin, unit, room)
      STAFF.to_h do |key, spec|
        user = User.find_or_initialize_by(email_address: "#{spec[:email_prefix]}@#{slug}.demo")
        user.password = password
        user.save!
        Membership.find_or_create_by!(user: user, role: "health_professional") { |membership| membership.granted_at = Time.current }
        SignatureCrew.ensure_totp(user, secret_env: spec[:secret_env], default_secret: spec[:default_secret])
        user = user.reload
        profile!(slug, user, spec, admin, unit)
        link!(room, user, spec[:role], admin)
        [ key, user ]
      end
    end

    def profile!(slug, user, spec, admin, unit)
      unless user.professional
        seed = "#{slug}:vaccination:#{spec[:email_prefix]}"
        attrs = { professional_name: spec[:name], cns: Professionals::Cns.generate(seed), council: "COREN",
                  council_state: CityProfile.current&.uf.presence || "PR", registration_number: (Zlib.crc32(seed) % 90_000 + 10_000).to_s }
        check!(Professionals::Create.call(user_id: user.id, attrs: attrs, by: admin), "perfil de #{spec[:name]}")
        user.reload
      end
      return if user.professional.links.active.exists?(health_unit_id: unit.id, cbo_code: spec[:cbo])

      check!(Professionals::OpenLink.call(professional: user.professional, health_unit_id: unit.id, cbo_code: spec[:cbo], by: admin),
             "vínculo de #{spec[:name]}")
    end

    def link!(room, user, role, admin)
      linked = Vaccination::LinkRoomStaff.call(room: room, user_id: user.id, role: role, by: admin)
      check!(linked, "vínculo de #{user.email_address} à sala") unless linked.ok? || linked.reason == :already_linked
    end

    # O CNS da vacinadora no retrato mais recente do CNES da cidade, no CNES da
    # unidade (é o que a NT 115 confere antes do envio). Sem retrato, grava um
    # mínimo. -> false quando a cidade não tem IBGE.
    def cnes_bond!(unit, vaccinator)
      ibge = CityProfile.current&.ibge_code
      return false if ibge.blank?

      cns = vaccinator.professional.cns
      cbo = STAFF.fetch(:vaccinator).fetch(:cbo)
      snapshot = CnesSnapshot.where(ibge_code: ibge).order(competence: :desc).first
      if snapshot.nil?
        Cnes::SnapshotWriter.write!(competence: Time.zone.today.prev_month.strftime("%Y%m"), ibge_code: ibge, teams: [],
                                    establishments: [ { cnes: unit.cnes, name: unit.name.upcase, unit_type: "02" } ],
                                    bonds: [ { cnes: unit.cnes, ine: nil, cbo_code: cbo, cpf: nil, cns: cns } ])
      elsif snapshot.bonds.where(cnes: unit.cnes).none? { |bond| bond.cns.to_s.gsub(/\D/, "") == cns }
        CnesProfessionalBond.create!(snapshot: snapshot, cnes: unit.cnes, ine: nil, cbo_code: cbo, cpf: nil, cns: cns)
      end
      true
    end

    # --- rede de frio, estoque e equipamento ----------------------------------

    def central!(admin, keeper)
      central = StockLocation.find_by(kind: "cold_chain_central") ||
                check!(Vaccination::CreateColdChainCentral.call(name: CENTRAL, by: admin), "rede de frio").payload.fetch(:location)
      linked = Pharmacy::LinkStaff.add(location: central, user_id: keeper.id, role: "stock_keeper", by: admin)
      check!(linked, "vínculo do almoxarife à rede de frio") unless linked.ok? || linked.reason == :already_linked
      central
    end

    # Abertura na rede de frio (uma por produto) e UMA transferência para a
    # sala, recebida pela responsável. Lote achado pelo (código, número).
    def stock!(central, room, keeper:, lead:)
      today = Time.zone.today
      pending = LOTS.reject { |spec| StockOpening.exists?(stock_location_id: central.id, immunobiological_code: spec[:code]) }
      if pending.any?
        items = pending.map do |spec|
          doses = Vaccination::Immunobiologicals.find(spec[:code]).doses_per_vial
          { "immunobiological_code" => spec[:code], "manufacturer_key" => spec[:key], "lot_number" => spec[:lot],
            "expires_on" => (today + spec[:days]).iso8601, "package" => { "units_per_package" => doses, "packages" => spec[:vials] } }
        end
        check!(Pharmacy::RecordEntry.call(location: central, kind: "opening", document: nil, items: items, by: keeper, catalog: {}), "abertura da rede de frio")
      end
      return if StockTransfer.exists?(from_location_id: central.id, to_location_id: room.stock_location_id)

      items = LOTS.map { |spec| { "lot_id" => lot(spec).id, "quantity" => spec[:to_room] } }
      sent = check!(Pharmacy::SendTransfer.call(from: central, to: room.stock_location, items: items, by: keeper), "envio à sala")
      transfer = sent.payload.fetch(:transfer)
      received = transfer.items.map { |item| { "lot_id" => item.stock_lot_id, "quantity_received" => item.quantity_sent.to_s("F") } }
      check!(Pharmacy::ReceiveTransfer.call(transfer: transfer, items: received, by: lead), "recebimento na sala")
    end

    def lot(spec) = StockLot.find_by!(item_kind: "immunobiological", immunobiological_code: spec[:code], lot_number: spec[:lot])

    def equipment!(room)
      location = room.stock_location
      return if ColdChainEquipment.exists?(stock_location_id: location.id, name: EQUIPMENT)

      check!(Vaccination::SaveEquipment.call(attrs: { "name" => EQUIPMENT, "kind" => "refrigerator" }, location: location), "geladeira")
    end

    # --- credencial e dose ----------------------------------------------------

    # Certificado de teste (PFX autoassinado) que o fake-rnds aceita; a
    # credencial que já existe fica como está.
    def credential!(admin, unit)
      return if IntegrationCredential.exists?(kind: "rnds")

      secret = { "pfx_base64" => Base64.strict_encode64(test_pfx), "pfx_password" => CERTIFICATE_PASSWORD, "requester_cnes" => unit.cnes }
      IntegrationCredential.create!(kind: "rnds", secret: secret, set_by_user: admin, set_at: Time.current)
    end

    def test_pfx
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = SecureRandom.random_number(2**64)
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{CERTIFICATE_CN}")
      cert.public_key = key.public_key
      cert.not_before = Time.current - 1.day
      cert.not_after = Time.current + CERTIFICATE_YEARS.years
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
      OpenSSL::PKCS12.create(CERTIFICATE_PASSWORD, CERTIFICATE_CN, key, cert).to_der
    end

    # A criança (CPF e CNS fictícios com dígito válido, estáveis pela semente)
    # e a penta D1 do lote da sala; a caderneta fica conferida porque ela
    # nasceu depois do go-live (Statuses).
    def dose!(room, vaccinator, slug)
      seed = "#{slug}:vaccination:child"
      cpf = RecordModeCrew.cpf_for(seed)
      patient = Patient.find_by(cpf: cpf) ||
                Patient.create!(cpf: cpf, cns: Professionals::Cns.generate(seed), full_name: CHILD[:name], mother_name: CHILD[:mother], sex: CHILD[:sex],
                                birth_date: (Time.zone.today - CHILD[:age_days]).iso8601)
      return if Immunization.exists?(patient_id: patient.id)

      now = Time.current
      attrs = DOSE.merge("applied_at" => (now - 1.hour).iso8601, "lot_id" => lot(LOTS.first).id)
      check!(Vaccination::RecordImmunization.call(room: room, patient: patient, attrs: attrs, by: vaccinator, now: now), "dose de exemplo")
    end
  end
end
