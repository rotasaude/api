# Módulo 21b (ADR 0037): cidade com exam_tracking e municipal_lab, o
# laboratório municipal, exames adotados com versão, equipe do laboratório.
module LabHelpers
  GLUCOSE = [ { "key" => "glicose", "name" => "Glicose", "loinc" => "2345-7", "unit" => "mg/dL", "value_type" => "numeric",
                "choices" => [], "decimals" => 0,
                "reference_ranges" => [ { "sex" => "any", "age_min_days" => 0, "age_max_days" => 43_800, "low" => 70.0, "high" => 99.0, "text" => nil } ],
                "entry_min" => 10.0, "entry_max" => 1500.0, "critical_low" => 40.0, "critical_high" => 400.0, "formula" => nil } ].freeze
  LIPIDS = [
    { "key" => "ct", "name" => "Colesterol total", "loinc" => "2093-3", "unit" => "mg/dL", "value_type" => "numeric", "choices" => [], "decimals" => 0,
      "reference_ranges" => [], "entry_min" => nil, "entry_max" => nil, "critical_low" => nil, "critical_high" => nil, "formula" => nil },
    { "key" => "hdl", "name" => "HDL", "loinc" => "2085-9", "unit" => "mg/dL", "value_type" => "numeric", "choices" => [], "decimals" => 0,
      "reference_ranges" => [], "entry_min" => nil, "entry_max" => nil, "critical_low" => nil, "critical_high" => nil, "formula" => nil },
    { "key" => "tg", "name" => "Triglicerídeos", "loinc" => "2571-8", "unit" => "mg/dL", "value_type" => "numeric", "choices" => [], "decimals" => 0,
      "reference_ranges" => [], "entry_min" => nil, "entry_max" => nil, "critical_low" => nil, "critical_high" => nil, "formula" => nil },
    { "key" => "ldl", "name" => "LDL (Friedewald)", "loinc" => "13457-7", "unit" => "mg/dL", "value_type" => "numeric", "choices" => [], "decimals" => 0,
      "reference_ranges" => [], "entry_min" => nil, "entry_max" => nil, "critical_low" => nil, "critical_high" => nil, "formula" => "ct - hdl - tg / 5" }
  ].freeze

  def json_patch(path, params = {}) = patch(path, params: params.to_json, headers: { "CONTENT_TYPE" => "application/json" })

  def lab_city!(hl7: false, fake_middleware: false)
    city = exam_city!
    maintainer = ledi_maintainer!
    Platform::Features.set!(city: city, key: "municipal_lab", enabled: true, maintainer: maintainer)
    Platform::Features.set!(city: city, key: "lab_hl7_inbound", enabled: true, maintainer: maintainer) if hl7 || fake_middleware
    Platform::Features.set!(city: city, key: "fake_middleware", enabled: true, maintainer: maintainer) if fake_middleware
    CityCatalog.reset_cache!
    city
  end

  def lab_provider!(name: "Laboratório Municipal #{SecureRandom.hex(2)}")
    ExamProvider.create!(name: name, kind: "municipal", uses_municipal_lab: true, cnes: format("%07d", SecureRandom.random_number(9_000_000) + 1_000_000),
                         address: "Rua do Laboratório, 100 — Centro", phone: "4133501200")
  end

  def lab_exam!(provider:, sigtap_code: "0202010473", name: "Glicose", analytes: GLUCOSE, material: "Plasma",
                container: "Tubo cinza (fluoreto)", instrument_test_code: "GLI", sector: "biochemistry", delivery_days: 3)
    exam = LabExam.create!(exam_provider: provider, sigtap_code: sigtap_code, name: name, sector: sector, delivery_days: delivery_days)
    version = LabExamVersion.create!(lab_exam: exam, version: 1, analysis_method: "Enzimático", material: material, container: container,
                                     instrument_test_code: instrument_test_code, analytes: analytes, created_by_user: lab_admin!)
    exam.update!(current_version: version)
    exam
  end

  def lab_admin! = (@lab_admin ||= staff_with("admin-lab-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
  def lab_staff! = staff_with("tecnica-#{SecureRandom.hex(3)}@cidade.gov.br", "lab_staff")

  # Liberador com perfil (conselho do laboratório) e TOTP, ligado ao laboratório.
  def lab_releaser!(provider, council: "CRBM", lead: false, deputy: false)
    user = staff_with("liberador-#{SecureRandom.hex(3)}@cidade.gov.br", "lab_releaser")
    Professional.create!(user: user, professional_name: "Liberadora #{SecureRandom.hex(2)}", council: council, council_state: "PR",
                         registration_number: (SecureRandom.random_number(90_000) + 10_000).to_s,
                         cns: Professionals::Cns.generate("lab-#{user.id}"), cpf: nil)
    Mfa::Enroll.call(user)
    user.update!(otp_enabled: true)
    LabReleaser.create!(user: user, exam_provider: provider, technical_lead: lead, technical_deputy: deputy)
    user
  end

  def totp_for(user) = ROTP::TOTP.new(user.reload.otp_secret).now

  # Requisição pelo caminho real (posto do laboratório por padrão).
  def open_requisition!(provider:, exams:, unit: nil, place: "lab", by: nil, patient: nil)
    unit ||= create_unit("UBS #{SecureRandom.hex(2)}").tap { |u| u.update!(collects_samples: true) }
    patient ||= exam_patient!(exam_seq!).first
    requester = doctor!(unit)
    orders = exams.map { |exam| exam_order!(patient: patient, unit: unit, requester: requester, sigtap_code: exam.sigtap_code) }
    by ||= place == "lab" ? lab_staff! : requester
    result = Lab::OpenRequisition.call({ patient_id: patient.id, provider_id: provider.id, origin_unit_id: unit.id, collection_place: place,
                                         biological_sex: "female", mother_name: "Joana da Silva", urgent: false,
                                         exam_order_ids: orders.map(&:id) }, by: by)
    raise "requisição recusada: #{result.reason}" if result.failure?

    result.payload[:requisition]
  end

  # Requisição gravada direto (antes da Task 8): uma amostra, um item.
  def lab_requisition_row!(provider:, version:, unit: create_unit("UBS #{SecureRandom.hex(2)}"))
    patient = exam_patient!(exam_seq!).first
    order = exam_order!(patient: patient, unit: unit, requester: doctor!(unit), sigtap_code: version.lab_exam.sigtap_code)
    req = LabRequisition.create!(number: LabRequisition.next_number, patient: patient, exam_provider: provider, origin_unit: unit,
                                 collection_place: "lab", biological_sex: "female", mother_name: "Joana", urgent: false,
                                 expected_delivery_on: Time.zone.today + 3, opened_by_user: lab_staff!)
    sample = LabSample.create!(lab_requisition: req, barcode: LabSample.barcode_for(req.number, 1), material: version.material,
                               container: version.container)
    LabRequisitionItem.create!(lab_requisition: req, exam_order: order, lab_exam_version: version, lab_sample: sample)
    req
  end
end

RSpec.configure { |c| c.include LabHelpers }
