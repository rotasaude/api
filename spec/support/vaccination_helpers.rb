# Módulo 29 (ADR 0047): cidade da sala de vacina, sala com local de estoque,
# equipe com vínculo de vacinador, paciente com ou sem CPF/CNS, lote de
# imunobiológico com saldo na sala, rede de frio, equipamento, dose gravada
# direto no banco e a credencial RNDS com um PFX autoassinado. Tudo avaliado
# só na chamada.
module VaccinationHelpers
  # Cidade com prontuário próprio (record_mode: record), `vaccination` ligado
  # e os parâmetros da sala; com `rnds: true`, também `rnds_immunization`,
  # `rnds_mock` e a credencial `rnds`.
  def vaccination_city!(enabled: true, rnds: false)
    city = clinical_city!
    # O dump (db/city_schema.rb) não leva linha: a linha que a migração insere.
    VaccinationSetting.ensure_defaults!
    maintainer = ledi_maintainer!
    Platform::Features.set!(city: city, key: "vaccination", enabled: true, maintainer: maintainer) if enabled
    if rnds
      rnds_credential!
      %w[rnds_immunization rnds_mock].each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer) }
    end
    city
  end

  # PKCS#12 (DER) com chave RSA e certificado autoassinado que vence em
  # `not_after` (vencido quando no passado).
  def self_signed_pfx(password:, not_after:, common_name: "Rota Saude Teste")
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = SecureRandom.random_number(2**64)
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{common_name}")
    cert.public_key = key.public_key
    cert.not_after = not_after.to_time
    cert.not_before = [ Time.current, cert.not_after ].min - 365.days
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    OpenSSL::PKCS12.create(password, common_name, key, cert).to_der
  end

  # Credencial `rnds` da cidade, direto no banco (validada pelo modelo).
  def rnds_credential!(cnes: "1234567", password: "rnds-teste")
    secret = { "pfx_base64" => Base64.strict_encode64(self_signed_pfx(password: password, not_after: 1.year.from_now)),
               "pfx_password" => password, "requester_cnes" => cnes }
    IntegrationCredential.find_or_initialize_by(kind: "rnds").tap do |credential|
      credential.assign_attributes(secret: secret, set_by_user: pharmacy_admin!, set_at: Time.current)
      credential.save!
    end
  end

  def cold_chain_central!
    StockLocation.find_by(kind: "cold_chain_central") ||
      StockLocation.create!(kind: "cold_chain_central", name: "Rede de frio municipal", updated_by_user: pharmacy_admin!)
  end

  # Sala com o local de estoque vaccine_room da unidade.
  def vaccine_room!(unit = create_unit("UBS Vacina #{SecureRandom.hex(2)}"))
    admin = pharmacy_admin!
    location = StockLocation.create!(kind: "vaccine_room", name: "Sala de vacina #{unit.name}", health_unit: unit, updated_by_user: admin)
    VaccineRoom.create!(health_unit: unit, stock_location: location, name: "Sala de vacina #{unit.name}", updated_by_user: admin)
  end

  # Membership health_professional, vínculo profissional na unidade da sala
  # com o CBO (vacinador 3222*/2235*/225*) e o vínculo ativo à sala (Desvio 6).
  def room_member!(room, role: "vaccinator", cbo: "322205")
    user = screener!(room.health_unit, cbo: cbo, email: "#{role.tr('_', '-')}-#{SecureRandom.hex(3)}@cidade.gov.br")
    VaccineRoomStaff.create!(vaccine_room: room, user: user, role: role, granted_by_user: pharmacy_admin!, granted_at: Time.current)
    user
  end

  # Paciente com nascimento e sexo; CPF e CNS válidos e únicos por chamada, ou
  # sem eles (sem CPF: a justificativa 3 da ficha).
  def vaccine_patient!(birth_date:, sex: "female", cpf: true, cns: true)
    n = registry_seq!
    Patient.create!(cpf: (valid_cpf(n) if cpf), no_cpf_reason: ("3" unless cpf), cns: (valid_cns(n) if cns),
                    full_name: "Ana Clara Souza #{n}", mother_name: "Beatriz Souza", birth_date: birth_date.to_date.iso8601, sex: sex)
  end

  # Lote de imunobiológico com `doses` de saldo no local da sala: lote, nota e
  # movimento de recebimento gravados direto (o caminho real, pelas rotas do
  # 27a, nasce na Task 6). `place`: a sala ou um local de estoque.
  def vaccine_lot!(place, code: "42", doses: 10, lot_number: "L#{SecureRandom.hex(3).upcase}", expires_on: Time.zone.today + 180,
                   manufacturer_key: nil)
    admin = pharmacy_admin!
    location = place.is_a?(VaccineRoom) ? place.stock_location : place
    lot = StockLot.create!(item_kind: "immunobiological", immunobiological_code: code, lot_number: lot_number, expires_on: expires_on.to_date,
                           manufacturer_key: manufacturer_key, dispensing_unit: "dose", created_by_user: admin)
    entry = StockEntry.create!(stock_location: location, kind: "invoice", document_number: "GUIA-#{SecureRandom.hex(3)}",
                               supplier: "Rede de frio municipal", recorded_by_user: admin)
    StockMovement.create!(stock_location: location, stock_lot: lot, immunobiological_code: code, kind: "receipt", quantity: doses,
                          stock_entry: entry, recorded_by_user: admin, recorded_at: Time.current)
    lot
  end

  # `place`: a sala (VaccineRoom) ou um local de estoque (a rede de frio).
  def cold_chain_equipment!(place, name: "Geladeira #{SecureRandom.hex(2)}", min_c: 2, max_c: 8)
    location = place.is_a?(VaccineRoom) ? place.stock_location : place
    ColdChainEquipment.create!(stock_location: location, name: name, kind: "refrigerator", min_c: min_c, max_c: max_c)
  end

  # Bloqueio aberto do lote no local (leitura fora da faixa e excursão aberta),
  # gravado direto no banco (o caminho real nasce na Task 14).
  def lot_block!(location, lot)
    reading = ColdChainReading.create!(cold_chain_equipment: cold_chain_equipment!(location), current_c: 9.5, min_c: 2, max_c: 9.5,
                                       read_at: Time.current, recorded_by_user: pharmacy_admin!)
    excursion = ColdChainExcursion.create!(cold_chain_reading: reading, stock_location: location)
    StockLotBlock.create!(cold_chain_excursion: excursion, stock_location: location, stock_lot: lot)
  end

  # Dose de penta (D1) aplicada na sala, gravada direto no banco (sem comando,
  # sem movimento de estoque nem fila). `over` troca qualquer coluna.
  def create_immunization!(room, **over)
    attrs = { patient: -> { vaccine_patient!(birth_date: Time.zone.today - 61) }, vaccine_room: room, health_unit: room.health_unit,
              vaccinator_user: -> { room_member!(room) }, vaccinator_cbo: "322205", immunobiological_code: "42", dose_code: "1",
              strategy: "1", care_group: "121", route: "3", site: "18", maternal_condition: "1", applied_at: Time.current,
              transcription: false, stock_lot: -> { vaccine_lot!(room) }, calendar_version: "2026.1" }.merge(over)
    Immunization.create!(attrs.transform_values { |value| value.is_a?(Proc) ? value.call : value })
  end
end

RSpec.configure { |c| c.include VaccinationHelpers }
