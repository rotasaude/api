# spec/support/controlled_prescription_helpers.rb
require_relative "../../lib/fake_sncr/app"

# Módulo 19d (ADR 0034): cidade com receita controlada, SNCR simulado e real
# servidos pelo FakeSncr::App (WebMock#to_rack), itens do catálogo com lista e
# marcas, contato do prescritor e identificação do paciente.
module ControlledPrescriptionHelpers
  ADDRESS = { "street" => "Rua das Araucárias", "number" => "120", "district" => "Centro", "city" => "Curitiba",
              "uf" => "PR", "zip" => "80010000" }.freeze
  # CPF mandado na entrada por engano: o api ignora (vale o do cadastro).
  PATIENT_CPF = "52998224725".freeze
  FAKE_SNCR_BASE = "http://fake-sncr.test/api/v1".freeze
  SNCR_REAL_BASE = "https://sncr-gateway.test/api-sncr/api/v1".freeze
  SNCR_REAL_AUTH = "https://sncr-auth.test/api/v1".freeze
  MAINTAINER_CNPJ = "11222333000181".freeze

  def controlled_city!(mock: true, signature: true)
    city = documents_city!
    maintainer = ledi_maintainer!
    Platform::Features.set!(city: city, key: "digital_signature", enabled: true, maintainer: maintainer) if signature
    Platform::Features.set!(city: city, key: "controlled_prescriptions", enabled: true, maintainer: maintainer)
    Platform::Features.set!(city: city, key: "sncr_mock", enabled: true, maintainer: maintainer) if mock
    CityCatalog.reset_cache!
    city
  end

  def fake_sncr = @fake_sncr ||= FakeSncr::App.new(start_block: 1)

  def stub_sncr_mock!
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("FAKE_SNCR_URL").and_return(FAKE_SNCR_BASE)
    allow(ENV).to receive(:[]).with("FAKE_SNCR_PUBLIC_URL").and_return("http://localhost:8092/api/v1")
    stub_request(:any, /\A#{Regexp.escape(FAKE_SNCR_BASE)}/).to_rack(fake_sncr)
  end

  def stub_sncr_real!
    allow(Sncr::Config).to receive(:credentials)
      .and_return("base_url" => SNCR_REAL_BASE, "auth_url" => SNCR_REAL_AUTH, "maintainer_cnpj" => MAINTAINER_CNPJ)
    [ SNCR_REAL_BASE, SNCR_REAL_AUTH ].each { |base| stub_request(:any, /\A#{Regexp.escape(base)}/).to_rack(fake_sncr) }
  end

  # Estoque direto (sem SNCR): um lote de `count` números a partir do próximo livre.
  def sncr_stock!(user, kind: "rce", count: 3, simulated: true)
    prefix = "2610.#{kind == 'rce' ? 1 : 2}-41."
    start = SncrNumber.where(kind: kind).where("number LIKE ?", "#{prefix}%").count + 1
    block = Sncr::Client::Block.new(first: "#{prefix}#{start.to_s.rjust(7, '0')}",
                                    last: "#{prefix}#{(start + count - 1).to_s.rjust(7, '0')}", quantity: count)
    Sncr::Stock.record_batch!(user: user, kind: kind, block: block, simulated: simulated)
  end

  # Item de catálogo sintético (código fora do recorte de dev), com a lista de
  # controle e as marcas dadas. O banco de plataforma é compartilhado e uma
  # reaplicação de marcas (apply_to_catalog!) pode ter mexido no item: as
  # marcas são regravadas a cada chamada.
  def controlled_item!(code:, ingredient:, list: nil, antimicrobial: false, anticonvulsant: false, strength: "200 mg", dosage_form: "COMPRIMIDO")
    flags = { controlled: list.present?, controlled_list: list.presence, antimicrobial: antimicrobial, anticonvulsant: anticonvulsant }
    existing = MedicationCatalogItem.find_by(catmat_code: code)
    return existing.tap { |item| item.update!(flags) } if existing

    release = MedicationCatalogRelease.current || raise("catálogo sem release: chame import_test_catalog! antes")
    MedicationCatalogItem.create!(flags.merge(catmat_code: code, active_ingredient: ingredient, strength: strength, dosage_form: dosage_form,
                                              source_description: "#{ingredient} #{strength}", search_text: ingredient.downcase,
                                              parse_status: "ok", first_release_id: release.id, last_release_id: release.id))
  end

  def prescriber_contact!(user, phone: "41999990000")
    user.professional.update!(prescriber_address: ADDRESS.to_json, phone: phone)
    user
  end

  def patient_identification(**over)
    # Entrada (contrato §2 do 19d): só o endereço; o CPF é o do cadastro, preenchido pelo api.
    { "address" => ADDRESS }.merge(over.stringify_keys)
  end
end

RSpec.configure { |config| config.include ControlledPrescriptionHelpers }
