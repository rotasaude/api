# spec/invariants/clinical_documents_invariants_spec.rb
require "rails_helper"

# Critério de fechamento do 19c (ADR 0033, "Invariantes"). Cada bloco diz a
# mutação que precisa deixá-lo vermelho.
RSpec.describe "Invariantes dos documentos clínicos (ADR 0033)", type: :request do
  before { documents_city!; ciap2_release!; cid10_release!; sigtap_release!; import_test_catalog!; city_cnpj! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }
  let(:marker) { "MARCADOR#{SecureRandom.hex(4)}" }

  def issue(kind, content, by: doctor, on: consultation) = ClinicalDocuments::Issue.call(kind: kind, content: content, by: by, consultation: on)

  # Mutação: tirar o ramo issued → cancelled de rota_clinical_document_guard, ou o not_author do Cancel.
  it "documento emitido não muda; só é cancelado, pela autora, com motivo" do
    document = issue("sick_note", { "type" => "leave", "days" => 1 }).payload[:document]
    expect { document.update!(content: { "type" => "leave", "days" => 9 }.to_json) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(ClinicalDocuments::Cancel.call(document_id: document.id, by: doctor!(unit), reason: "Motivo qualquer longo").reason).to eq(:not_author)
    expect(ClinicalDocuments::Cancel.call(document_id: document.id, by: doctor, reason: "curto").reason).to eq(:invalid_reason)
    expect(ClinicalDocuments::Cancel.call(document_id: document.id, by: doctor, reason: "Motivo qualquer longo")).to be_ok
  end

  # Mutação: aceitar paper → digital, ou digital → paper com assinatura gravada.
  it "o modo nunca é convertido (só a volta ao papel sem assinatura)" do
    paper = issue("sick_note", { "type" => "leave", "days" => 1 }).payload[:document]
    expect { paper.update!(issue_mode: "digital") }.to raise_error(ActiveRecord::StatementInvalid)
    signed = raw_document!(consultation: consultation, issue_mode: "digital")
    request = SignatureRequest.create!(document_type: "ClinicalDocument", document_id: signed.id, consultation_id: consultation.id,
                                       author_user_id: doctor.id)
    signature_row!(request, certificate: linked_certificate!(doctor.tap { |u| u.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF) }))
    expect { signed.update!(issue_mode: "paper") }.to raise_error(ActiveRecord::StatementInvalid)
  end

  # Mutação: tirar a checagem de controlado (catálogo ou texto) ou o `!antimicrobial` do modo.
  it "nenhum controlado emitido; antimicrobiano só em papel" do
    item = ->(code) { { "catalog_item" => { "id" => catalog_item(code).id }, "quantity" => 10, "quantity_unit" => "comprimido",
                        "route" => "oral", "dosage_instructions" => "1 ao dia" } }
    expect(issue("prescription", { "items" => [ item.(273_009) ] }).reason).to eq(:controlled_not_allowed)
    expect(issue("prescription", { "items" => [ { "free_text" => "Clonazepam 2mg", "quantity" => 10, "quantity_unit" => "cp",
                                                  "route" => "oral", "dosage_instructions" => "1 à noite" } ] }).reason).to eq(:controlled_not_allowed)
    signature_city!
    linked_certificate!(doctor.tap { |u| u.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF) })
    expect(issue("prescription", { "items" => [ item.(267_625) ] }).payload[:document].issue_mode).to eq("paper")
    expect(ClinicalDocument.where(kind: "prescription").map { |d| d.content_data["items"].any? { |i| i.dig("catalog_item", "catmat_code").in?([ 267_197, 273_009 ]) } }).to all(be(false))
  end

  # Mutação: aceitar versão não vigente ou item fora do protocolo.
  it "enfermeiro só prescreve itens de protocolo vigente" do
    nurse = nurse!(unit)
    nursing = finalized_consultation!(unit: unit, doctor: nurse, citizen: verified_citizen!(2, full_name: "Rita Souza"))
    catalog = { catalog_item(267_503).id => catalog_item(267_503) }
    expired = NursingProtocols::Save.create(params: { "title" => "Antigo", "number" => "PE-00", "year" => 2025, "valid_from" => "2025-01-01",
                                                      "valid_until" => "2025-12-31", "items" => [ { "catalog_item_id" => catalog_item(267_503).id } ] },
                                            by: municipal_admin!, catalog: catalog).payload[:protocol].versions.sole
    content = { "nursing_protocol" => { "version_id" => expired.id },
                "items" => [ { "catalog_item" => { "id" => catalog_item(267_503).id }, "quantity" => 30, "quantity_unit" => "comprimido",
                               "route" => "oral", "dosage_instructions" => "1 ao dia" } ] }
    expect(issue("prescription", content, by: nurse, on: nursing).reason).to eq(:not_in_nursing_protocol)
  end

  # Mutação: pôr cid10, items ou days no public_json/na página.
  it "a página pública nunca mostra CID, medicamento, dias ou CPF" do
    document = issue("sick_note", { "type" => "leave", "days" => 7, "cid10" => { "code" => "E119" }, "cid_authorized" => true }).payload[:document]
    get "/v/#{document.verification_token}", headers: { "Accept" => "application/json" }
    json = response.body
    get "/v/#{document.verification_token}"
    expect(json + response.body).not_to include("E119", "Diabetes", "\"days\"", "7 dia", consultation.patient.cpf)
    expect(JSON.parse(json).keys - %w[kind issued_at professional unit patient status mode simulated cancelled_at signed_pdf_url]).to eq([])
  end

  # Mutação: tirar o patient_medications_guard ou o CHECK de fonte do evento.
  it "patient_medications só muda por evento ligado a consulta, adendo ou documento" do
    expect { PatientMedication.create!(patient: consultation.patient, free_text: "Chá", label: "Chá", status: "active", origin: "external") }
      .to raise_error(ActiveRecord::StatementInvalid)
    expect { PatientMedicationEvent.create!(patient_medication_id: SecureRandom.uuid, kind: "added", user: doctor, status_after: "active") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_patient_medication_events_source/)
  end

  # Mutação: pôr content/cancel_reason/nome em evento, log ou mensagem; tirar :content/:short_code do filtro.
  it "nenhum conteúdo de documento em log, evento, job, Analytics ou erro" do
    log = capture_log do
      sign_in_as(doctor)
      json_post "/attendance/consultations/#{consultation.id}/documents", kind: "sick_note",
                content: { type: "leave", days: 2, note: "nota #{marker}" }
      id = json_body["id"]
      # `issuer_registration` só é coberto por `:content` no filtro (os outros textos têm chave própria).
      json_post "/attendance/consultations/#{consultation.id}/documents", kind: "attendance_declaration",
                content: { period: "morning", issuer_registration: marker }
      expect(response).to have_http_status(:created)
      json_post "/attendance/consultations/#{consultation.id}/documents", kind: "sick_note", content: { type: "leave", days: 2, note: "#{marker} " * 200 }
      expect(response.body).not_to include(marker)
      stepped_up!(doctor)
      json_post "/attendance/documents/#{id}/cancel", reason: "motivo #{marker}"
      json_post "/attendance/consultations/#{consultation.id}/documents", kind: "prescription",
                content: { items: [ { free_text: "Remédio #{marker}", quantity: 1, quantity_unit: "caixa", route: "oral", dosage_instructions: "1 ao dia" } ] }
      json_post "/v/lookup", short_code: marker, birth_year: 1980
    end
    [ log, DomainEvent.pluck(:payload).to_json, PlatformEvent.pluck(:payload).to_json,
      ActiveJob::Base.queue_adapter.enqueued_jobs.to_json ].each { |text| expect(text).not_to include(marker) }
    analytics = Dir[Rails.root.join("app/services/analytics/**/*.rb")].map { |f| File.read(f) }.join
    expect(analytics).not_to match(/clinical_documents|prescription_items|patient_medications/)
  end
end

# Mutação: tirar o `d.txid = txid_current()` de rota_prescription_item_insert_guard.
RSpec.describe "prescription_items: documento de outra transação não basta (ADR 0033)" do
  self.use_transactional_tests = false

  let(:document_id) { SecureRandom.uuid }
  let(:conn) { ApplicationRecord.connection }

  before do
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        conn.execute("SET LOCAL session_replication_role = replica")
        conn.execute(<<~SQL)
          INSERT INTO clinical_documents (id, kind, patient_id, citizen_id, consultation_id, attendance_id, author_user_id, cbo_code,
                                          issue_mode, verification_token, short_code, issued_at, content, created_at)
          VALUES ('#{document_id}', 'prescription', gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
                  gen_random_uuid(), '225125', 'paper', '#{'A' * 22}', '#{'2' * 10}', now(), 'x', now())
        SQL
      end
    end
  end

  after do
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        conn.execute("SET LOCAL session_replication_role = replica")
        conn.execute("DELETE FROM prescription_items WHERE clinical_document_id = '#{document_id}'")
        conn.execute("DELETE FROM clinical_documents WHERE id = '#{document_id}'")
      end
    end
  end

  it "recusa item novo de receita commitada antes" do
    CityConnection.with(TEST_CITY_A) do
      expect do
        ApplicationRecord.transaction do
          conn.execute(<<~SQL)
            INSERT INTO prescription_items (id, clinical_document_id, position, free_text, printed_description, quantity, quantity_unit,
                                            route, dosage_instructions, created_at)
            VALUES (gen_random_uuid(), '#{document_id}', 1, 'x', 'x', 1, 'cx', 'oral', 'x', now())
          SQL
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /born with their prescription/)
    end
  end
end


# Sem fixture transacional: as linhas de partida são commitadas antes (replica, sem os triggers)
# e cada tentativa roda numa transação NOVA, que é desfeita mesmo se o banco aceitar (`rolled_back`:
# uma mutação que solte a guarda não apaga nada de verdade). O after apaga o que o before gravou
# (só o banco da cidade é gravado; nada na plataforma).
RSpec.describe "protocolos e medicamentos em uso: o banco é a última palavra (ADR 0033)" do
  self.use_transactional_tests = false

  let(:conn) { ApplicationRecord.connection }
  let(:protocol_id) { SecureRandom.uuid }
  let(:version_id) { SecureRandom.uuid }
  let(:medication_id) { SecureRandom.uuid }
  let(:orphan_medication_id) { SecureRandom.uuid }
  let(:medication) { PatientMedication.find(medication_id) }
  let(:event) { PatientMedicationEvent.find_by!(patient_medication_id: medication_id) }

  def as_replica(&) = ApplicationRecord.transaction do
    conn.execute("SET LOCAL session_replication_role = replica")
    yield
  end

  def rolled_back = ApplicationRecord.transaction do
    yield
    raise ActiveRecord::Rollback
  end

  def reencrypting(&) = rolled_back { CityEncryption.allowing_reencryption(&) }

  def seed_event!(medication_id)
    PatientMedicationEvent.new(patient_medication_id: medication_id, kind: "added", status_after: "active",
                               user_id: SecureRandom.uuid, consultation_id: SecureRandom.uuid,
                               dosage_summary: "1 comprimido ao dia").save!(validate: false)
  end

  def new_medication(id) = PatientMedication.new(id: id, patient_id: SecureRandom.uuid, free_text: "Losartana 50mg",
                                                 label: "Losartana 50mg", dosage_summary: "1 comprimido ao dia",
                                                 status: "active", origin: "external", continuous: true)

  before do
    as_replica do
      conn.execute(<<~SQL)
        INSERT INTO nursing_protocols (id, title, number, year, created_by_user_id, created_at)
        VALUES ('#{protocol_id}', 'Saúde da mulher', 'PE-#{protocol_id.first(8)}', 2026, gen_random_uuid(), now())
      SQL
      conn.execute(<<~SQL)
        INSERT INTO nursing_protocol_versions (id, nursing_protocol_id, version, valid_from, created_by_user_id, created_at)
        VALUES ('#{version_id}', '#{protocol_id}', 1, '2026-01-01', gen_random_uuid(), now())
      SQL
      new_medication(medication_id).save!(validate: false)
      seed_event!(medication_id)
      seed_event!(orphan_medication_id)
    end
  end

  after do
    as_replica do
      conn.execute("DELETE FROM nursing_protocol_version_items WHERE nursing_protocol_version_id = '#{version_id}'")
      conn.execute("DELETE FROM nursing_protocol_versions WHERE id = '#{version_id}'")
      conn.execute("DELETE FROM nursing_protocols WHERE id = '#{protocol_id}'")
      PatientMedicationEvent.where(patient_medication_id: [ medication_id, orphan_medication_id ]).delete_all
      PatientMedication.where(id: [ medication_id, orphan_medication_id ]).delete_all
    end
  end

  # Mutação: tirar o `v.txid = txid_current()` de rota_nursing_protocol_item_insert_guard.
  it "recusa item novo de versão de protocolo commitada antes" do
    expect do
      rolled_back do
        conn.execute(<<~SQL)
          INSERT INTO nursing_protocol_version_items (id, nursing_protocol_version_id, catalog_item_id, created_at)
          VALUES (gen_random_uuid(), '#{version_id}', gen_random_uuid(), now())
        SQL
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /born with their version/)
  end

  # Mutação: tirar o `e.txid = txid_current()` de rota_patient_medication_guard.
  it "recusa mudar ou criar medicamento com o evento de outra transação" do
    expect { rolled_back { medication.update_columns(status: "suspended") } }
      .to raise_error(ActiveRecord::StatementInvalid, /event of the same transaction/)
    expect { rolled_back { new_medication(orphan_medication_id).save!(validate: false) } }
      .to raise_error(ActiveRecord::StatementInvalid, /event of the same transaction/)
    expect(PatientMedication.where(id: orphan_medication_id)).not_to exist
  end

  # Mutação: tirar o ramo rota.reencrypting de rota_patient_medication_guard ou a lista de
  # colunas de um *_reencryption_only (re-cifra recusada); comparar só parte da linha
  # (coluna não cifrada aceita sob a marca).
  it "re-cifra: os textos cifrados são regravados sob a marca; nada mais" do
    expect { reencrypting { medication.encrypt } }.not_to raise_error
    expect { reencrypting { event.encrypt } }.not_to raise_error
    expect { reencrypting { medication.update_columns(continuous: false) } }
      .to raise_error(ActiveRecord::StatementInvalid, /event of the same transaction/)
    expect { reencrypting { event.update_columns(kind: "changed") } }
      .to raise_error(ActiveRecord::StatementInvalid, /patient_medication_events is append-only: UPDATE refused/)
    expect([ medication.reload.label, event.reload.dosage_summary ]).to eq([ "Losartana 50mg", "1 comprimido ao dia" ])
  end

  # Mutação: tirar o DELETE ou a checagem de identidade de rota_patient_medication_guard, o
  # *_reencryption_only dos eventos ou um *_append_only_truncate.
  it "medicamento em uso nunca some nem troca de identidade; o evento é só acréscimo" do
    expect { rolled_back { medication.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    expect { rolled_back { medication.update_columns(patient_id: SecureRandom.uuid) } }
      .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
    expect { rolled_back { conn.execute("TRUNCATE patient_medications CASCADE") } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { rolled_back { event.update_columns(status_after: "suspended") } }
      .to raise_error(ActiveRecord::StatementInvalid, /patient_medication_events is append-only: UPDATE refused/)
    expect { rolled_back { event.delete } }
      .to raise_error(ActiveRecord::StatementInvalid, /patient_medication_events is append-only: DELETE refused/)
    expect { rolled_back { conn.execute("TRUNCATE patient_medication_events") } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect(PatientMedication.where(id: medication_id).pluck(:status)).to eq([ "active" ])
  end
end

# Mutação: tirar o prescription_items_reencryption_only, a lista de colunas cifradas passada
# a ele, ou o *_append_only_truncate da tabela. Cada recusa num savepoint próprio (`refused`).
RSpec.describe "prescription_items: só acréscimo e re-cifra (ADR 0033)" do
  before { clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }
  let(:item) do
    ApplicationRecord.transaction do
      document = raw_document!(consultation: consultation, kind: "prescription", content: { "items" => [] })
      PrescriptionItem.create!(clinical_document: document, position: 1, free_text: "Chá de camomila",
                               printed_description: "Chá de camomila", quantity: 1, quantity_unit: "sachê",
                               route: "oral", dosage_instructions: "1 sachê à noite")
    end
  end

  def refused(&) = ApplicationRecord.transaction(requires_new: true, &)

  it "os textos cifrados são regravados sob a marca; nada mais; nunca some" do
    item # fora da marca: criar a consulta toca o paciente, que não aceita mudança sob a re-cifra
    expect { CityEncryption.allowing_reencryption { item.reload.encrypt } }.not_to raise_error
    expect(item.reload.dosage_instructions).to eq("1 sachê à noite")
    expect { refused { CityEncryption.allowing_reencryption { item.reload.update_columns(quantity: 2) } } }
      .to raise_error(ActiveRecord::StatementInvalid, /prescription_items is append-only: UPDATE refused/)
    expect { refused { item.reload.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    expect { refused { ApplicationRecord.connection.execute("TRUNCATE prescription_items") } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end
end
