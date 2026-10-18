require "zlib"
require_relative "fake_middleware/qc_plan"

# Semente de dev do módulo 21c (ADR 0038). Dev é fictício mas imita o real:
# no "Laboratório Municipal Central" de Curitiba (do LabCrew), um Mindray
# BS-240 (bioquímica, BIO-01) e um Sysmex XN-350 (hematologia, HEM-01),
# classe de aparelho dos editais municipais; as versões dos exames de
# bioquímica e hematologia ganham o aparelho; material Lyphochek (Bio-Rad)
# de dois níveis com o lote, os códigos e a bula de FakeMiddleware::QcPlan
# (o simulado manda corridas contra eles); referência da bula aceita pela
# RT há 25 dias; 20 corridas aprovadas de história (uma por dia, z
# alternando de lado), que liberam a sugestão da referência do laboratório;
# estoque com reagentes de glicose (um lote vencendo) e creatinina (abaixo
# do mínimo) e tubos; lote em uso no BIO-01. Opera com as contas do 21b.
# Só Curitiba. Idempotente. Roda depois do LabCrew.
class LabQcCrew
  SWITCHES = %w[lab_quality_control lab_inventory].freeze
  PLAN = FakeMiddleware::QcPlan
  # Fabricante, modelo e identificador vêm do QcPlan (fonte única); setor e série são só da semente.
  INSTRUMENT_EXTRAS = { "BIO-01" => { "sector" => "biochemistry", "serial_number" => "BS240-2023-0417", "label" => "Analisador bioquímico 1" },
                        "HEM-01" => { "sector" => "hematology", "serial_number" => "XN350-2022-1189", "label" => "Analisador hematológico 1" } }.freeze
  INSTRUMENTS = PLAN::INSTRUMENTS.map do |equipment_id, (full_name, manufacturer)|
    extras = INSTRUMENT_EXTRAS.fetch(equipment_id)
    { "name" => extras["label"], "manufacturer" => manufacturer, "model" => full_name.delete_prefix("#{manufacturer} "),
      "serial_number" => extras["serial_number"], "sector" => extras["sector"], "hl7_equipment_id" => equipment_id }
  end.freeze
  SECTOR_INSTRUMENT = INSTRUMENTS.to_h { |i| [ i["sector"], i["hl7_equipment_id"] ] }.freeze
  MATERIAL = { "name" => PLAN::MATERIAL, "manufacturer" => PLAN::MANUFACTURER }.freeze
  # z de cada corrida da história contra a bula (Nível 1; o Nível 2 leva o sinal trocado): alternando de lado, nenhuma regra dispara.
  HISTORY_Z = [ 0.3, -0.5, 0.8, -0.2, 0.6, -0.9, 0.4, -0.3, 1.1, -0.6, 0.2, -0.4, 0.7, -0.8, 0.5, -0.1, 0.9, -0.7, 0.3, -0.2 ].freeze
  TARGETS_DAYS_AGO = 25
  SUPPLIER = "Distribuidora Paranaense de Diagnósticos Ltda.".freeze
  # lots: [número, dias até vencer, embalagens]
  SUPPLIES = [
    { "name" => "Glicose GOD-PAP — kit 500 testes", "kind" => "reagent", "unit" => "kit", "tests_per_package" => 500, "minimum_stock" => 2,
      "sigtap" => %w[0202010473], "lots" => [ [ "GL2609", 240, 4 ], [ "GL2603", 20, 1 ] ], "in_use" => "GL2609", "opened" => { "GL2609" => 1 } },
    { "name" => "Creatinina Jaffé — kit 300 testes", "kind" => "reagent", "unit" => "kit", "tests_per_package" => 300, "minimum_stock" => 3,
      "sigtap" => %w[0202010317], "lots" => [ [ "CR2611", 300, 2 ] ], "in_use" => "CR2611", "opened" => {} },
    { "name" => "Tubo de coleta 4 mL com fluoreto", "kind" => "consumable", "unit" => "caixa com 100", "tests_per_package" => nil, "minimum_stock" => 10,
      "sigtap" => [], "lots" => [ [ "TF2512", 400, 25 ] ], "in_use" => nil, "opened" => {} }
  ].freeze

  class << self
    def seed_current_city(slug:, admin:)
      raise "semente da qualidade: ambiente implantado; a semente é só de dev" if Rota.deployed?
      return { switch: "desligado (só Curitiba liga)", created: [] } unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: LabCrew::DEV_MAINTAINER)
      return { switch: "desligado (sem mantenedor #{LabCrew::DEV_MAINTAINER})", created: [] } unless maintainer

      city = City.find(Current.city.id)
      SWITCHES.each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer) }
      lab = ExamProvider.find_by!(name: LabCrew::LAB)
      staff = User.find_by!(email_address: "tecnica-lab@#{slug}.demo")
      lead = User.find_by!(email_address: "biomedica@#{slug}.demo")
      created = []
      instruments = instruments!(lab, created)
      link_versions!(lab, instruments, admin, created)
      quality_control!(lab, instruments.fetch(PLAN::INSTRUMENT), lead, staff, created)
      inventory!(lab, instruments.fetch(PLAN::INSTRUMENT), staff, created)
      { switch: "ligado (#{SWITCHES.join(', ')})", created: created }
    end

    private

    def check!(result, what)
      raise "semente da qualidade: #{what} recusado (#{result.reason})" if result.failure?

      result.payload
    end

    def instruments!(lab, created)
      INSTRUMENTS.to_h do |spec|
        found = LabInstrument.find_by(exam_provider_id: lab.id, hl7_equipment_id: spec["hl7_equipment_id"])
        unless found
          found = check!(Lab::SaveInstrument.call(spec.merge("provider_id" => lab.id, "active" => true)), "aparelho #{spec['hl7_equipment_id']}")[:instrument]
          created << "aparelho #{spec['hl7_equipment_id']}"
        end
        [ spec["hl7_equipment_id"], found ]
      end
    end

    # Nova versão (nunca edita) com o aparelho do setor, para os exames que ainda não têm.
    def link_versions!(lab, instruments, admin, created)
      LabExam.where(exam_provider_id: lab.id, active: true, sector: SECTOR_INSTRUMENT.keys).includes(:current_version).order(:name).each do |exam|
        version = exam.current_version
        next if version.nil? || version.lab_instrument_id

        params = { "method" => version.analysis_method, "material" => version.material, "container" => version.container,
                   "instrument_test_code" => version.instrument_test_code, "analytes" => version.analytes,
                   "lab_instrument_id" => instruments.fetch(SECTOR_INSTRUMENT.fetch(exam.sector)).id }
        check!(Lab::CreateVersion.call(exam: exam, params: params, by: admin), "versão de #{exam.sigtap_code}")
        created << "versão #{exam.sigtap_code}"
      end
    end

    def quality_control!(lab, instrument, lead, staff, created)
      since = Time.current - TARGETS_DAYS_AGO.days
      exams = PLAN::ANALYTES.keys.to_h do |code|
        [ code, LabExam.where(exam_provider_id: lab.id).joins(:current_version).find_by!(lab_exam_versions: { instrument_test_code: code }) ]
      end
      material = LabQcMaterial.find_by(exam_provider_id: lab.id, name: MATERIAL["name"]) || begin
        analytes = PLAN::ANALYTES.map { |code, (key, _unit)| { "lab_exam_id" => exams.fetch(code).id, "analyte_key" => key } }
        created << "material de controle"
        check!(Lab::Qc::SaveMaterial.call(MATERIAL.merge("levels" => PLAN::BARCODES.keys, "analytes" => analytes, "active" => true), provider: lab),
               "material")[:material]
      end
      lot = material.lots.find_by(lot_number: PLAN::LOT) || begin
        created << "lote #{PLAN::LOT}"
        check!(Lab::Qc::CreateLot.call({ "material_id" => material.id, "lot_number" => PLAN::LOT, "expires_on" => (Time.zone.today + 300).iso8601,
                                         "level_barcodes" => PLAN::BARCODES }, by: lead, now: since), "lote")[:lot]
      end
      PLAN::TARGETS.each do |level, by_code|
        by_code.each do |code, (mean, sd, _decimals)|
          key = PLAN::ANALYTES.fetch(code).first
          next if LabQcTarget.current(lot_id: lot.id, level: level, analyte_key: key, instrument_id: instrument.id)

          check!(Lab::Qc::CreateTarget.call({ "lot_id" => lot.id, "level" => level, "analyte_key" => key, "instrument_id" => instrument.id,
                                              "mean" => mean, "sd" => sd }, by: lead, now: since), "referência #{key} #{level}")
        end
      end
      history!(lot, instrument, staff, created) unless LabQcValue.exists?(lab_qc_lot_id: lot.id)
    end

    # Uma corrida por dia, de 21 a 2 dias atrás, às 7h30 (abertura da rotina), digitada pela técnica.
    def history!(lot, instrument, staff, created)
      HISTORY_Z.each_with_index do |z, i|
        day = (Time.zone.today - (HISTORY_Z.size + 1 - i)).in_time_zone.change(hour: 7, min: 30)
        PLAN::BARCODES.keys.each_with_index do |level, li|
          PLAN::ANALYTES.each do |code, (key, _unit)|
            value = BigDecimal(PLAN.value(level, code, li.zero? ? z : -z))
            payload = check!(Lab::Qc::RecordValue.call(instrument: instrument, lot: lot, level: level, analyte_key: key, value: value,
                                                       source: "typed", by: staff, now: day + li.minutes), "controle #{key} #{level}")
            raise "semente da qualidade: a história reprovou (#{key} #{level})" unless payload[:value].outcome == "ok"
          end
        end
      end
      created << "#{HISTORY_Z.size} corridas aprovadas"
    end

    def inventory!(lab, instrument, staff, created)
      SUPPLIES.each do |spec|
        exam_ids = LabExam.where(exam_provider_id: lab.id, sigtap_code: spec["sigtap"]).pluck(:id)
        supply = LabSupply.where(exam_provider_id: lab.id).find_by("lower(name) = ?", spec["name"].downcase) || begin
          created << "item #{spec['name']}"
          attrs = spec.slice("name", "kind", "unit", "tests_per_package", "minimum_stock").merge("expiry_alert_days" => 30, "lab_exam_ids" => exam_ids,
                                                                                                  "active" => true)
          check!(Lab::Inventory::SaveSupply.call(attrs, provider: lab), "item #{spec['name']}")[:supply]
        end
        spec["lots"].each do |number, days, quantity|
          next if LabSupplyLot.exists?(lab_supply_id: supply.id, lot_number: number)

          lot = check!(Lab::Inventory::ReceiveLot.call({ "supply_id" => supply.id, "lot_number" => number, "expires_on" => (Time.zone.today + days).iso8601,
                                                         "supplier" => SUPPLIER, "origin" => "purchase", "quantity" => quantity,
                                                         "document" => "NF-e #{(Zlib.crc32(number) % 900_000) + 100_000}" }, by: staff), "lote #{number}")[:lot]
          opened = spec["opened"].fetch(number, 0)
          check!(Lab::Inventory::RecordMovement.call(lot: lot, kind: "opening", quantity: opened, reason: nil, by: staff, admin: false), "abertura") if opened.positive?
        end
        next unless spec["in_use"]

        lot = LabSupplyLot.find_by!(lab_supply_id: supply.id, lot_number: spec["in_use"])
        exam_ids.each { |exam_id| check!(Lab::Inventory::SetInUse.call(lot_id: lot.id, instrument_id: instrument.id, lab_exam_id: exam_id, by: staff), "lote em uso") }
      end
    end
  end
end
