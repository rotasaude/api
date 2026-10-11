# spec/invariants/controlled_prescriptions_invariants_spec.rb
require "rails_helper"

# ADR 0034 — Invariantes. Cada bloco nomeia a mutação que o deixa vermelho.
# A corrida de duas emissões ao mesmo tempo (SKIP LOCKED) NÃO é provada aqui:
# emissões em sequência não provam concorrência. Vive em
# spec/services/sncr/stock_race_spec.rb (threads e conexões separadas).
RSpec.describe "Invariantes do ADR 0034" do
  before do
    controlled_city!(mock: true)
    ciap2_release!; cid10_release!; sigtap_release!; city_profile!
    import_test_catalog!
  end

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit).tap { |user| prescriber_contact!(user); linked_certificate!(user) } }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }

  def item(code, ingredient, list) = controlled_item!(code: code, ingredient: ingredient, list: list)

  def line(catalog) = { "catalog_item" => { "id" => catalog.id }, "quantity" => 30, "quantity_unit" => "comprimido", "route" => "oral",
                        "dosage_instructions" => "1 ao dia", "duration_days" => 30 }

  def rce_content(catalog = item(9_900_001, "FLUOXETINA", "C1"))
    { "items" => [ line(catalog) ], "patient_identification" => patient_identification }
  end

  def issue(content = rce_content) = ClinicalDocuments::Issue.call(kind: "prescription", by: doctor, consultation: consultation, content: content)

  # Mutação: tirar o índice único ou o gatilho de transição de SncrNumber (a
  # exclusão mútua do SKIP LOCKED é a stock_race_spec).
  it "um número SNCR nunca é usado duas vezes" do
    sncr_stock!(doctor, kind: "rce", count: 2)
    documents = 3.times.map { issue.payload[:document] }
    numbers = documents.filter_map { |document| document.content_data.dig("sncr", "number") }
    expect(numbers).to eq(numbers.uniq)
    expect(numbers.size).to eq(2)
    used = SncrNumber.where(status: "used").first
    expect { used.update!(document_id: documents.last.id) }.to raise_error(ActiveRecord::StatementInvalid)
    expect { SncrNumber.create!(batch: used.batch, user: doctor, kind: used.kind, number: used.number, simulated: true) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  # Mutação: cancelar sem void!, ou um gatilho que aceite voided → free.
  it "número de receita cancelada não volta" do
    sncr_stock!(doctor, kind: "rce", count: 1)
    document = issue.payload[:document]
    ClinicalDocuments::Cancel.call(document_id: document.id, by: doctor, reason: "Emitida para o paciente errado")
    number = SncrNumber.find_by(document_id: document.id)
    expect(number.status).to eq("voided")
    expect { number.update!(status: "free", document_id: nil, used_at: nil, voided_at: nil) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(issue.payload[:paper_reason]).to eq("no_sncr_number")
  end

  # Mutação: tirar `environments:` do sncr_mock, a guarda de env do Stock ou do Config, ou o abort do config.ru.
  it "nenhum número simulado em produção" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("FAKE_SNCR_URL").and_return(ControlledPrescriptionHelpers::FAKE_SNCR_BASE)
    expect(Platform::Features.catalog(env: "production").map(&:key)).not_to include("sncr_mock")
    expect(Sncr::Mock.on?(Current.city, env: "production")).to be(false)
    expect(Sncr::Config.simulated(env: "production")).to be_nil
    allow(Sncr::Config).to receive(:credentials).and_return({})
    expect { Sncr::Client.for(Current.city, env: "production") }.to raise_error(Sncr::Client::Unavailable)
    sncr_stock!(doctor, kind: "rce", count: 1, simulated: true)
    expect(ApplicationRecord.transaction { Sncr::Stock.take!(user: doctor, kind: "rce", simulated: true, env: "production") }).to be_nil
    allow(ENV).to receive(:[]).with("RAILS_ENV").and_return("production")
    allow(ENV).to receive(:[]).with("RACK_ENV").and_return("production")
    expect { Rack::Builder.parse_file(Rails.root.join("lib/fake_sncr/config.ru").to_s) }
      .to raise_error(SystemExit).and output(/fake-sncr/).to_stderr
  end

  # Mutação: gravar simulated false (ou omitir) ao consumir um número simulado.
  it "documento com número simulado é sempre sncr.simulated true" do
    sncr_stock!(doctor, kind: "rce", count: 2, simulated: true)
    documents = 2.times.map { issue.payload[:document] }
    expect(documents.map { |document| document.content_data.dig("sncr", "simulated") }).to eq([ true, true ])
    expect(SncrNumber.where(document_id: documents.map(&:id)).pluck(:simulated)).to eq([ true, true ])
  end

  # Mutação: aceitar enfermeiro em special_control, ou tirar NOTIFICATION/UNSUPPORTED do Controlled.
  it "controle especial só por médico ou dentista; nunca A, B, C2, C3 em receita" do
    sncr_stock!(doctor, kind: "rce", count: 1)
    expect(issue.payload[:document].content_data["category"]).to eq("special_control")
    { "A1" => :requires_notification, "A2" => :requires_notification, "A3" => :requires_notification,
      "B1" => :requires_notification, "B2" => :requires_notification, "C2" => :not_supported, "C3" => :not_supported }
      .each_with_index do |(list, reason), index|
        expect(issue(rce_content(item(9_900_200 + index, "SUBSTANCIA #{list}", list))).reason).to eq(reason)
      end
    expect(ClinicalDocuments::Content::Controlled.check("special_control", [], role: :nurse, identification: nil, prescriber_contact: nil,
                                                        patient: nil).reason)
      .to eq(:cbo_not_allowed)
    issued = ClinicalDocument.where(kind: "prescription").flat_map { |document| document.content_data["items"].map { |i| i.dig("catalog_item", "id") } }
    lists = MedicationCatalogItem.where(id: issued.compact).pluck(:controlled_list).compact
    expect(lists).to eq([ "C1" ]) # só a válida existe; nenhuma A, B, C2 ou C3 foi gravada
  end

  # Mutação: afrouxar o classify da Task 11 (aceitar item comum ou texto livre em RCE/RET).
  it "RCE/RET nunca levam item comum nem texto livre (interruptor ligado)" do
    sncr_stock!(doctor, kind: "rce", count: 1)
    sncr_stock!(doctor, kind: "ret", count: 1)
    fluoxetina = item(9_900_001, "FLUOXETINA", "C1")
    losartana = controlled_item!(code: 268_856, ingredient: "LOSARTANA POTÁSSICA")
    amoxicilina = controlled_item!(code: 271_089, ingredient: "AMOXICILINA", antimicrobial: true)
    paracetamol = controlled_item!(code: 9_900_300, ingredient: "PARACETAMOL")
    free = { "free_text" => "Dipirona 500mg gotas", "quantity" => 1, "quantity_unit" => "frasco", "route" => "oral",
             "dosage_instructions" => "20 gotas", "duration_days" => 3 }
    before_count = ClinicalDocument.count
    [ [ fluoxetina, losartana ], [ amoxicilina, paracetamol ] ].each do |first, second|
      result = issue("items" => [ line(first), line(second) ], "patient_identification" => patient_identification)
      expect([ result.reason, result.details ]).to eq([ :mixed_categories, { index: 1 } ])
    end
    retfree = issue("items" => [ line(amoxicilina), free ])
    expect([ retfree.reason, retfree.details ]).to eq([ :mixed_categories, { index: 1 } ])
    special_free = issue("items" => [ line(fluoxetina), free ], "patient_identification" => patient_identification)
    expect([ special_free.reason, special_free.details ]).to eq([ :mixed_categories, { index: 1 } ])
    expect(ClinicalDocument.count).to eq(before_count)
    expect(SncrNumber.where(user_id: doctor.id).pluck(:status)).to eq(%w[free free])
  end

  # Mutação: deixar o texto livre antimicrobiano tirar número ou virar RET.
  it "só texto livre antimicrobiano (interruptor ligado): papel free_text_items, nenhum número tirado" do
    sncr_stock!(doctor, kind: "ret", count: 1)
    result = issue("items" => [ { "free_text" => "Azitromicina 500mg", "quantity" => 3, "quantity_unit" => "comprimido", "route" => "oral",
                                  "dosage_instructions" => "1 ao dia", "duration_days" => 3 } ]).payload
    expect([ result[:document].issue_mode, result[:paper_reason], result[:document].paper_reason ]).to eq([ "paper", "free_text_items", "free_text_items" ])
    expect(result[:document].content_data["sncr"]).to be_nil
    expect(SncrNumber.where(user_id: doctor.id).pluck(:status, :document_id)).to eq([ [ "free", nil ] ])
  end

  # Mutação: decidir digital sem certificado, ou não abrir o pedido de assinatura junto com o número.
  it "receita digital de controle especial só com assinatura ICP (pedido nasce na emissão)" do
    sncr_stock!(doctor, kind: "rce", count: 2)
    issue
    other = signer_doctor!(unit, cpf: "11144477735").tap { |user| prescriber_contact!(user) }
    sncr_stock!(other, kind: "rce", count: 1)
    ClinicalDocuments::Issue.call(kind: "prescription", by: other, content: rce_content,
                                  consultation: finalized_consultation!(unit: unit, doctor: other, citizen: verified_citizen!(2)))
    special = ClinicalDocument.where(kind: "prescription").select { |document| document.content_data["category"] == "special_control" }
    special.select(&:digital?).each do |document|
      expect(document.signature_request).to be_present
      expect(document.content_data["sncr"]).to be_present
      expect(SignerCertificate.active.exists?(user_id: document.author_user_id)).to be(true)
    end
    expect(special.reject(&:digital?).map { |document| document.content_data["sncr"] }).to all(be_nil)
    expect(special.count(&:digital?)).to eq(1)
  end

  # Mutação: tirar o void! da volta ao papel (Signatures::ToPaper).
  it "RCE que voltou ao papel: número voided e fora da página pública" do
    sncr_stock!(doctor, kind: "rce", count: 2)
    document = issue.payload[:document]
    Signatures::ReturnToPaper.call(request_id: document.signature_request.id, by: doctor, reason: "Paciente pediu o papel agora")
    expect(document.reload.issue_mode).to eq("paper")
    expect(SncrNumber.find_by(document_id: document.id).status).to eq("voided")
    expect(ClinicalDocuments::Json.document(document)[:content]["sncr"]).to be_nil # FW1: a leitura não devolve o número anulado
    json = ClinicalDocuments::Verification.public_json(document)
    expect(json).not_to have_key(:sncr)
    expect(json.to_json).not_to include(SncrNumber.find_by(document_id: document.id).number)
  end

  # Mutação: pôr número, CPF ou endereço no payload de um evento de emissão/cancelamento.
  it "número, CPF e endereço nunca em evento publicado pelas emissões" do
    sncr_stock!(doctor, kind: "rce", count: 3)
    sncr_stock!(doctor, kind: "ret", count: 1)
    first = issue.payload[:document]
    issue("items" => [ line(controlled_item!(code: 271_089, ingredient: "AMOXICILINA", antimicrobial: true)) ])
    issue("items" => [ { "free_text" => "Azitromicina 500mg", "quantity" => 3, "quantity_unit" => "comprimido", "route" => "oral",
                         "dosage_instructions" => "1 ao dia", "duration_days" => 3 } ])
    ClinicalDocuments::Cancel.call(document_id: first.id, by: doctor, reason: "Emitida para o paciente errado")
    diazepam = controlled_item!(code: 9_900_003, ingredient: "DIAZEPAM", list: "B1")
    record = ClinicalDocuments::Issue.call(kind: "controlled_notification_record", by: doctor, consultation: consultation,
                                           content: { "notification_type" => "B", "paper_number" => "PR-1234567", "numbering_uf" => "PR",
                                                      "item" => line(diazepam) })
    expect(record.failure?).to be(false), record.inspect
    expect(DomainEvent.where(name: "controlled_notification.recorded").count).to eq(1)
    secrets = SncrNumber.pluck(:number) + [ consultation.patient.cpf, doctor.professional.cpf, "Araucárias", "80010000", "Rua das", "PR-1234567" ]
    expect(secrets.size).to be > 4
    payloads = DomainEvent.pluck(:payload).to_json
    expect(DomainEvent.where(name: %w[sncr.number_used sncr.number_voided]).count).to be >= 2
    secrets.each { |secret| expect(payloads).not_to include(secret) }
  end
end

# Mutação: gravar o token numa coluna, logar o session_id, pôr o número ou o CPF num evento.
RSpec.describe "Invariantes do ADR 0034 — nada sensível fora do lugar", type: :request do
  before do
    controlled_city!(mock: true)
    stub_sncr_mock!
    ciap2_release!; cid10_release!; sigtap_release!; city_profile!
    import_test_catalog!
  end

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit).tap { |user| prescriber_contact!(user); linked_certificate!(user) } }

  it "token e session_id nunca persistidos; número, CPF e endereço fora de log e evento" do
    sign_in_as(doctor)
    session_id = nil
    log = capture_log do
      post "/sncr/requests", params: { kind: "rce" }, as: :json
      started = JSON.parse(response.body)
      url = URI.decode_www_form(URI(started["authorize_url"]).query).to_h.fetch("client_url")
      session_id = fake_sncr.approve!(url)
      post "/sncr/oauth/callback", params: { state: started["state"], session_id: session_id }, as: :json
      consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
      post "/attendance/consultations/#{consultation.id}/documents", as: :json, params: {
        kind: "prescription",
        content: { items: [ { catalog_item: { id: controlled_item!(code: 9_900_001, ingredient: "FLUOXETINA", list: "C1").id },
                              quantity: 30, quantity_unit: "comprimido", route: "oral", dosage_instructions: "1 ao dia",
                              duration_days: 30 } ],
                   patient_identification: patient_identification }
      }
    end
    number = SncrNumber.where(status: "used").pick(:number)
    patient_cpf = ClinicalDocument.where(kind: "prescription").last.patient.cpf
    expect(fake_sncr.issued_tokens).not_to be_empty # a troca ocorreu no fake: a checagem de token não é vácua
    expect(DomainEvent.where(name: "sncr.numbers_requested")).to exist
    secrets = fake_sncr.issued_tokens + [ session_id, number, patient_cpf, "Araucárias" ] +
              SncrNumberBatch.pluck(:first_number, :last_number).flatten + SncrNumber.pluck(:number)
    expect(log).not_to include(*secrets)
    expect(DomainEvent.pluck(:payload).to_json).not_to include(*secrets)
    rows = SignatureOauthState.where(user_id: doctor.id).map { |row| row.attributes.values.join("|") }.join
    expect(rows).not_to include(*fake_sncr.issued_tokens, session_id)
  end
end
