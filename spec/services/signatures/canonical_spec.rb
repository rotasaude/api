require "rails_helper"

RSpec::Matchers.define_negated_matcher :exclude, :include unless RSpec::Matchers.method_defined?(:exclude)

# ADR 0032 (spec §7; contrato §10): o JSON canônico da consulta e do adendo na
# forma dos esquemas da tag clinical-v1.0.0 (fechados), determinístico, com a
# cadeia previous_sha256 (Desvio 1). Review Focus 5. Overrides 1–5 e 7: o adendo
# lê item_changes, exam_requests [] sai, IMC nulo some, todo exame leva a
# competência, inteiros onde o esquema pede inteiros.
RSpec.describe Signatures::Canonical do
  before { Current.city = signature_city!; ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  let(:unit) { create_unit("UBS Jardim das Flores") }
  let(:doctor) { signer_doctor!(unit) }
  let(:citizen) { verified_citizen!(1, social_name: "Mariana") }
  let(:competence) { Time.zone.today.strftime("%Y%m") }

  def add_addendum!(consultation, reason:, text:, changes: nil)
    result = Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: reason, text: text, changes: changes)
    raise "adendo recusado: #{result.reason} #{result.details}" if result.failure?

    result.payload[:addendum]
  end

  it "consulta: cabeçalho, conteúdo clínico com rótulos e competência, horários UTC, CPF só dígitos, inteiros" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen, objective: "")
    built = described_class.consultation(consultation)
    doc = built.document
    expect(doc.keys).to match_array(%w[schema city unit professional patient consultation])
    expect(doc["schema"]).to eq("rotasaude.consultation.v1")
    patient = consultation.patient
    expect(doc["patient"]).to eq("display_name" => "Mariana", "cpf" => patient.cpf, "birth_date" => patient.birth_date.presence)
    expect(doc["patient"]["cpf"]).to match(/\A\d{11}\z/)
    professional = doctor.professional
    expect(doc["professional"]).to eq("name" => professional.professional_name, "cpf" => SignatureHelpers::DOCTOR_CPF,
                                      "cbo_code" => "225125",
                                      "council" => { "name" => professional.council, "state" => professional.council_state,
                                                     "registration_number" => professional.registration_number })
    expect(doc["unit"]).to include("name" => "UBS Jardim das Flores")
    expect(doc["unit"]).to have_key("cnes")
    expect(doc["city"]).to have_key("ibge_code")
    body = doc["consultation"]
    expect(body).to include("id" => consultation.id, "care_type" => 5, "subjective" => "Refere sede e poliúria há dois meses",
                            "objective" => nil, "conducts" => [ 1 ], "outcome" => { "code" => "discharged" })
    expect(body["care_type"]).to be_a(Integer)
    expect(body["conducts"]).to all(be_a(Integer))
    expect(body["finalized_at"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    expect(body["started_at"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    expect(body["evaluated_problems"].sole)
      .to eq("terminology" => "ciap2", "code" => "T90", "label" => "Diabetes não insulino-dependente",
             "release" => TerminologyRelease.active.find_by(kind: "ciap2").version, "action" => "add",
             "onset_on" => "2025-08-01", "onset_precision" => "month")
    expect(body["exam_requests"].sole)
      .to eq("sigtap_code" => "0202010503", "competence" => competence, "label" => "DOSAGEM DE HEMOGLOBINA GLICOSILADA")
    expect(body["vitals"]).to eq("systolic" => 130, "diastolic" => 85, "weight_kg" => 82.5, "height_cm" => 170, "bmi" => 28.5)
    expect(body["vitals"]["height_cm"]).to be_a(Integer)
    expect(built.json).to eq(Signatures::Jcs.dump(doc))
    expect(built.sha256).to eq(Digest::SHA256.hexdigest(built.json))
    expect(described_class.for(consultation).sha256).to eq(built.sha256)
  end

  it "IMC nulo não entra: sem peso e altura, vitals sem a chave bmi (o esquema recusa null)" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen, vitals: { "systolic" => 120, "diastolic" => 80 })
    vitals = described_class.consultation(consultation).document.dig("consultation", "vitals")
    expect(vitals).to eq("systolic" => 120, "diastolic" => 80)
    expect(vitals).not_to have_key("bmi")
  end

  it "determinístico: o mesmo documento, o mesmo sha256; texto difícil não quebra (Review Focus 5)" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen,
                                           subjective: "PA ≥ 140 😷 “aspas” \r\nlinha nova", plan: "y" * 20_000)
    first = described_class.consultation(consultation)
    second = described_class.consultation(Consultation.find(consultation.id))
    expect(second.sha256).to eq(first.sha256)
    expect(second.json).to eq(first.json)
    expect(first.json).to include("PA ≥ 140 😷 “aspas” \\r\\nlinha nova")
    expect(first.document.dig("consultation", "plan").length).to eq(20_000)
    expect(first.json.encoding).to eq(Encoding::UTF_8)
    expect(first.json).to be_valid_encoding
  end

  it "adendo: cabeçalho da autora da consulta, changes de item_changes na forma do esquema, cadeia previous_sha256" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    one = add_addendum!(consultation, reason: "primeiro adendo aqui", text: "Texto UM")
    built_one = described_class.addendum(one)
    expect(built_one.document["schema"]).to eq("rotasaude.consultation_addendum.v1")
    expect(built_one.document["professional"]).to include("cpf" => SignatureHelpers::DOCTOR_CPF, "cbo_code" => consultation.cbo_code)
    expect(built_one.document["addendum"])
      .to include("consultation_id" => consultation.id, "id" => one.id, "reason" => "primeiro adendo aqui", "text" => "Texto UM",
                  "changes" => {}, "previous_sha256" => described_class.consultation(consultation).sha256) # nada assinado: a consulta
    expect(described_class.for(one).sha256).to eq(built_one.sha256)

    # o adendo 1 assinado: o 2 aponta para ele
    signature_row!(signature_request!(one, author: doctor, status: "signed"), certificate: linked_certificate!(doctor),
                   canonical_json: built_one.json)
    two = add_addendum!(consultation, reason: "segundo adendo aqui", text: "Texto DOIS",
                        changes: { "evaluated_problems" => [ { "terminology" => "cid10", "code" => "I10", "action" => "add" } ],
                                   "conducts" => [ 1, 2 ],
                                   "exam_requests" => [ { "sigtap_code" => "0202010503" }, { "sigtap_code" => "0202010317" } ] })
    expect(two.item_changes.keys).to match_array(%w[evaluated_problems conducts exam_requests])
    built_two = described_class.addendum(two)
    expect(built_two.document.dig("addendum", "previous_sha256")).to eq(built_one.sha256)
    changes = built_two.document.dig("addendum", "changes")
    expect(changes.keys).to match_array(%w[evaluated_problems conducts exam_requests])
    expect(changes["evaluated_problems"].sole)
      .to eq("terminology" => "cid10", "code" => "I10", "label" => "Hipertensão essencial (primária)",
             "release" => TerminologyRelease.active.find_by(kind: "cid10").version, "action" => "add")
    expect(changes["conducts"]).to eq([ 1, 2 ])
    expect(changes["conducts"]).to all(be_a(Integer))
    expect(changes["exam_requests"])
      .to eq([ { "sigtap_code" => "0202010503", "competence" => competence, "label" => "DOSAGEM DE HEMOGLOBINA GLICOSILADA" },
               { "sigtap_code" => "0202010317", "competence" => competence, "label" => "DOSAGEM DE CREATININA" } ])
    expect(described_class.addendum(ConsultationAddendum.find(two.id)).sha256).to eq(built_two.sha256)
  end

  it "adendo que cancela todos os exames: changes == { exam_requests: [] }, válido no esquema" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    addendum = add_addendum!(consultation, reason: "exame não é mais necessário", text: "Cancelo o exame",
                             changes: { "exam_requests" => [] })
    expect(addendum.item_changes).to eq("exam_requests" => [])
    built = described_class.addendum(addendum)
    expect(built.document.dig("addendum", "changes")).to eq("exam_requests" => [])
    expect { described_class.validate!(described_class::ADDENDUM_SCHEMA, built.document) }.not_to raise_error
    expect(built.json).to include('"changes":{"exam_requests":[]}')
  end

  it "a ordem das chaves em item_changes não muda o hash" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    addendum = add_addendum!(consultation, reason: "segundo adendo aqui", text: "DOIS",
                             changes: { "conducts" => [ 1, 2 ], "exam_requests" => [ { "sigtap_code" => "0202010317" } ] })
    original = described_class.addendum(addendum)
    reordered = addendum.item_changes.to_a.reverse.to_h { |key, value| [ key, value.is_a?(Array) ? value.map { |v| v.is_a?(Hash) ? v.to_a.reverse.to_h : v } : value ] }
    expect(reordered.keys).not_to eq(addendum.item_changes.keys)
    allow(addendum).to receive(:item_changes).and_return(reordered)
    expect(described_class.addendum(addendum).sha256).to eq(original.sha256)
  end

  it "cadeia pulando o não assinado: adendo 1 assinado, 2 não, o 3 aponta para o 1" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    one = add_addendum!(consultation, reason: "primeiro adendo aqui", text: "UM")
    add_addendum!(consultation, reason: "segundo adendo aqui", text: "DOIS")
    three = add_addendum!(consultation, reason: "terceiro adendo aqui", text: "TRES")
    signed = signature_row!(signature_request!(one, author: doctor, status: "signed"), certificate: linked_certificate!(doctor),
                            canonical_json: described_class.addendum(one).json)
    expect(described_class.addendum(three).document.dig("addendum", "previous_sha256")).to eq(signed.canonical_sha256)
  end

  it "previous_sha256 sem adendo anterior assinado: a assinatura da consulta, se houver" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    one = add_addendum!(consultation, reason: "primeiro adendo aqui", text: "UM")
    signed = signature_row!(signature_request!(consultation, author: doctor, status: "signed"), certificate: linked_certificate!(doctor),
                            canonical_json: "{\"consulta\":\"assinada antes\"}")
    expect(described_class.previous_sha256(one)).to eq(signed.canonical_sha256)
  end

  it "no lote: o adendo seguinte leva o hash do anterior já preparado (chain), mesmo sem assinatura gravada" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    one = add_addendum!(consultation, reason: "primeiro adendo aqui", text: "UM")
    two = add_addendum!(consultation, reason: "segundo adendo aqui", text: "DOIS")
    built_one = described_class.addendum(one)
    expect(described_class.addendum(two).document.dig("addendum", "previous_sha256"))
      .to eq(described_class.consultation(consultation).sha256) # sem chain: nada assinado
    chain = { [ "ConsultationAddendum", one.id ] => built_one.sha256 }
    expect(described_class.addendum(two, chain: chain).document.dig("addendum", "previous_sha256")).to eq(built_one.sha256)
    # a consulta preparada no mesmo lote conta como assinada para o primeiro adendo
    consultation_in_batch = { [ "Consultation", consultation.id ] => "b" * 64 }
    expect(described_class.previous_sha256(one, chain: consultation_in_batch)).to eq("b" * 64)
    expect(described_class.previous_sha256(two, chain: consultation_in_batch)).to eq("b" * 64)
  end

  it "rascunho não tem JSON canônico; documento fora do esquema levanta só com ponteiros" do
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
    expect { described_class.consultation(draft) }.to raise_error(described_class::Invalid)
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    doc = described_class.consultation(consultation).document
    cpf = consultation.patient.cpf
    expect { described_class.validate!(described_class::CONSULTATION_SCHEMA, doc.merge("signature" => { "x" => cpf })) }
      .to raise_error(described_class::Invalid) { |e| expect(e.message).to include("/signature").and(exclude(cpf)) }
    bad_patient = doc.merge("patient" => doc["patient"].merge("cpf" => "#{cpf}9"))
    expect { described_class.validate!(described_class::CONSULTATION_SCHEMA, bad_patient) }
      .to raise_error(described_class::Invalid) { |e| expect(e.message).to include("/patient/cpf").and(exclude(cpf)) }
    expect { described_class.for(Object.new) }.to raise_error(ArgumentError)
  end
end
