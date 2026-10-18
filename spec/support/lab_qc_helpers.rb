# Módulo 21c (ADR 0038): cidade com lab_quality_control (e lab_inventory),
# aparelho, exame ligado ao aparelho, material de dois níveis, lote e a
# referência da bula da glicose (Nível 1: 100 ± 5; Nível 2: 250 ± 10).
module LabQcHelpers
  GLUCOSE_QC = { "Nível 1" => %w[100 5], "Nível 2" => %w[250 10] }.freeze
  QcScenario = Struct.new(:provider, :instrument, :exam, :material, :lot, keyword_init: true)

  def qc_city!(inventory: false, hl7: false)
    city = lab_city!(hl7: hl7)
    maintainer = ledi_maintainer!
    Platform::Features.set!(city: city, key: "lab_quality_control", enabled: true, maintainer: maintainer)
    Platform::Features.set!(city: city, key: "lab_inventory", enabled: true, maintainer: maintainer) if inventory
    CityCatalog.reset_cache!
    city
  end

  def inventory_city!
    city = lab_city!
    Platform::Features.set!(city: city, key: "lab_inventory", enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    city
  end

  def qc_instrument!(provider, name: "Analisador bioquímico 1", hl7_equipment_id: "BIO-01", sector: "biochemistry")
    LabInstrument.create!(exam_provider: provider, name: name, manufacturer: "Mindray", model: "BS-240",
                          serial_number: "BS24-#{SecureRandom.hex(3)}", sector: sector, hl7_equipment_id: hl7_equipment_id, active: true)
  end

  # Exame cuja versão vigente está ligada ao aparelho.
  def qc_exam!(provider:, instrument:, sigtap_code: "0202010473", name: "Glicose", analytes: LabHelpers::GLUCOSE, instrument_test_code: "GLI")
    exam = LabExam.create!(exam_provider: provider, sigtap_code: sigtap_code, name: name, sector: instrument.sector, delivery_days: 2)
    version = LabExamVersion.create!(lab_exam: exam, version: 1, analysis_method: "Enzimático", material: "Plasma", container: "Tubo cinza (fluoreto)",
                                     instrument_test_code: instrument_test_code, analytes: analytes, created_by_user: lab_admin!,
                                     lab_instrument: instrument)
    exam.update!(current_version: version)
    exam
  end

  def qc_material!(provider, exams:, levels: [ "Nível 1", "Nível 2" ], name: "Controle bioquímico")
    analytes = exams.flat_map { |exam| exam.current_version.entered_analytes.map { |a| { "lab_exam_id" => exam.id, "analyte_key" => a["key"] } } }
    LabQcMaterial.create!(exam_provider: provider, name: name, manufacturer: "Bio-Rad", levels: levels, analytes: analytes, active: true)
  end

  def qc_lot!(material, lot_number: "L#{SecureRandom.hex(2).upcase}", expires_on: Time.zone.today + 300, barcodes: nil)
    lot = LabQcLot.create!(lab_qc_material: material, lot_number: lot_number, expires_on: expires_on, status: "in_use", opened_on: Time.zone.today)
    codes = barcodes || material.levels.each_with_index.to_h { |level, i| [ level, "CQ#{SecureRandom.hex(3).upcase}N#{i + 1}" ] }
    codes.each { |level, code| LabQcLotBarcode.create!(lab_qc_lot: lot, level: level, barcode: code, created_at: Time.current) }
    lot
  end

  def qc_target!(lot, level:, analyte_key:, instrument:, mean:, sd:, source: "package_insert", runs: nil, at: Time.current - 30.days, by: lab_admin!)
    version = LabQcTarget.where(lab_qc_lot_id: lot.id, level: level, analyte_key: analyte_key, lab_instrument_id: instrument.id).maximum(:version).to_i + 1
    LabQcTarget.create!(lab_qc_lot: lot, level: level, analyte_key: analyte_key, lab_instrument: instrument, version: version, source: source,
                        mean: BigDecimal(mean.to_s), sd: BigDecimal(sd.to_s), based_on_runs: runs, accepted_by_user: by, accepted_at: at, created_at: at)
  end

  def qc_scenario!(provider: lab_provider!)
    instrument = qc_instrument!(provider)
    exam = qc_exam!(provider: provider, instrument: instrument)
    material = qc_material!(provider, exams: [ exam ])
    lot = qc_lot!(material)
    GLUCOSE_QC.each { |level, (mean, sd)| qc_target!(lot, level: level, analyte_key: "glicose", instrument: instrument, mean: mean, sd: sd) }
    QcScenario.new(provider: provider, instrument: instrument, exam: exam, material: material, lot: lot)
  end

  # Valor da glicose do nível para um z da bula do cenário.
  def qc_glucose(level, z)
    mean, sd = GLUCOSE_QC.fetch(level)
    BigDecimal(mean) + (BigDecimal(sd) * BigDecimal(z.to_s))
  end

  def qc_value!(scenario, level, z = 0, by: nil, now: Time.current, analyte_key: "glicose", value: nil)
    result = Lab::Qc::RecordValue.call(instrument: scenario.instrument, lot: scenario.lot, level: level, analyte_key: analyte_key,
                                       value: value || qc_glucose(level, z), source: "typed", by: by || (@qc_staff ||= lab_staff!), now: now)
    raise "valor de controle recusado: #{result.reason}" if result.failure?

    result.payload
  end

  def comma(number) = BigDecimal(number.to_s).to_s("F").sub(/\.0\z/, "").tr(".", ",")
end

RSpec.configure { |c| c.include LabQcHelpers }
