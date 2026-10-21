# Módulo 22 (ADR 0039): SIGTAP de faturamento (instrumento, CBO, CID), a
# cidade com procedure_billing, UPA com CNES, faturista, configuração e
# procedimento cru (para as specs de banco). A SIGTAP é imutável depois de
# ativa: billing_sigtap! roda ANTES de exam_city!/lab_city! (o
# sigtap_release! deles reaproveita a competência que já existe).
module BillingHelpers
  # código => [nome, sexo, idade mínima, idade máxima (meses)]; atributos de teste.
  PROCEDURES = {
    "0301060029" => [ "ATENDIMENTO DE URGENCIA C/ OBSERVACAO ATE 24 HORAS EM ATENCAO ESPECIALIZADA", nil, nil, nil ],
    "0301060096" => [ "ATENDIMENTO MEDICO EM UNIDADE DE PRONTO ATENDIMENTO", nil, nil, nil ],
    "0301010072" => [ "CONSULTA MEDICA EM ATENCAO ESPECIALIZADA", nil, nil, nil ],
    "0301100012" => [ "ADMINISTRACAO DE MEDICAMENTOS NA ATENCAO ESPECIALIZADA.", nil, nil, nil ],
    "0301060118" => [ "ACOLHIMENTO COM CLASSIFICACAO DE RISCO", nil, nil, nil ],
    "0214010015" => [ "GLICEMIA CAPILAR", nil, nil, nil ],
    "0201020033" => [ "COLETA DE MATERIAL P/ EXAME CITOPATOLOGICO DE COLO UTERINO", "F", 300, 780 ],
    "0604320124" => [ "MEDICAMENTO DE TESTE REGISTRADO EM APAC", nil, nil, nil ]
  }.freeze
  INSTRUMENTS = {
    "0301060029" => %w[02], "0301060096" => %w[02], "0301010072" => %w[02], "0301010064" => %w[02], "0301100012" => %w[01],
    "0301060118" => %w[01], "0214010015" => %w[01], "0201020033" => %w[01 02], "0604320124" => %w[06],
    "0202010473" => %w[01], "0202020380" => %w[01], "0202010503" => %w[01], "0202010317" => %w[01]
  }.freeze
  CBOS = {
    "0301060029" => %w[225125 225124], "0301060096" => %w[225125 225124 225142], "0301010072" => %w[225125],
    "0301100012" => %w[223505 322205], "0301060118" => %w[223505 225125], "0214010015" => %w[223505 322205],
    "0201020033" => %w[223505 225125], "0202010473" => %w[221205], "0202020380" => %w[221205], "0202010503" => %w[221205],
    "0202010317" => %w[221205]
  }.freeze
  CIDS = { "0301060029" => %w[I10 E119] }.freeze
  REGISTRIES = { "01" => "BPA (CONSOLIDADO)", "02" => "BPA (INDIVIDUALIZADO)", "06" => "APAC (PROCEDIMENTO PRINCIPAL)" }.freeze

  def billing_sigtap!(competences = [ Time.zone.today.strftime("%Y%m"), Time.zone.today.prev_month.strftime("%Y%m") ])
    Array(competences).map do |competence|
      existing = TerminologyRelease.active.find_by(kind: "sigtap", version: competence)
      if existing
        raise "billing_sigtap! depois de exam_city!/lab_city!: chame antes" unless SigtapProcedureInstrument.exists?(release_id: existing.id)

        next existing
      end
      release = TerminologyRelease.create!(kind: "sigtap", version: competence, source_sha256: "b" * 64, imported_by: "rspec",
                                           imported_at: Time.current, status: "importing")
      ClinicalRecordHelpers::SIGTAP.transform_values { |name| [ name, nil, nil, nil ] }.merge(PROCEDURES).each do |code, (name, sex, min, max)|
        SigtapProcedure.create!(release: release, code: code, name: name, sex: sex, age_min_months: min, age_max_months: max)
      end
      INSTRUMENTS.each do |code, list|
        list.each { |reg| SigtapProcedureInstrument.create!(release: release, procedure_code: code, instrument_code: reg, instrument_name: REGISTRIES.fetch(reg)) }
      end
      CBOS.each { |code, list| list.each { |cbo| SigtapProcedureCbo.create!(release: release, procedure_code: code, cbo_code: cbo) } }
      CIDS.each { |code, list| list.each { |cid| SigtapProcedureCid.create!(release: release, procedure_code: code, cid_code: cid, principal: true) } }
      release.update!(status: "active", activated_at: Time.current)
      release
    end
  end

  # Cidade com procedure_billing ligado, CID-10, perfil com IBGE (4106902) e,
  # com lab: true, o laboratório municipal do 21b.
  def billing_city!(lab: false, record_mode: "record")
    billing_sigtap!
    city = lab ? lab_city! : clinical_city!(record_mode: record_mode)
    cid10_release!
    Platform::Features.set!(city: city, key: "procedure_billing", enabled: true, maintainer: ledi_maintainer!)
    city_profile!
    CityCatalog.reset_cache!
    city
  end

  def billing_cnes = format("%07d", SecureRandom.random_number(9_000_000) + 1_000_000)
  def upa!(name = "UPA #{SecureRandom.hex(2)}", cnes: billing_cnes) = HealthUnit.create!(name: name, kind: "upa", cnes: cnes)
  def billing_clerk! = staff_with("faturista-#{SecureRandom.hex(3)}@cidade.gov.br", "billing_clerk")
  # D-U1: o paciente de teste nasce com raça/cor e endereço (faturável no BPA-I); demographics: false para a pendência.
  DEMOGRAPHICS = { race_color: "03", ethnicity: nil, address_zip: "80010000", address_street: "Rua XV de Novembro",
                   address_number: "1200", address_complement: nil, address_district: "Centro" }.freeze

  def billing_patient!(demographics: true, **citizen_attrs)
    patient = exam_patient!(exam_seq!, **citizen_attrs).first
    patient.update!(DEMOGRAPHICS) if demographics
    patient
  end

  def billing_settings!(by: lab_admin!)
    BillingSetting.current ||
      BillingSetting.create!(origin_name: "SMS Curitiba", origin_cnpj: "11222333000181", destination_body: "Secretaria Municipal de Saude",
                             management: "M", updated_by_user: by)
  end

  # Procedimento gravado direto (specs de banco); o caminho real é Billing::Record (Task 5).
  def raw_procedure!(unit:, patient:, professional:, **over)
    PerformedProcedure.create!({ patient: patient, health_unit: unit, professional_user: professional, cbo_code: "225125",
                                 performed_on: Time.zone.today, sigtap_code: "0301060029", quantity: 1, cid10: "I10",
                                 source: "manual", recorded_by_user: professional, instrument: "bpa_i", billable: true,
                                 blocking_reasons: [] }.merge(over))
  end
end

RSpec.configure { |c| c.include BillingHelpers }
