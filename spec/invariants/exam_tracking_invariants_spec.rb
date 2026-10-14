require "rails_helper"

# ADR 0036, Invariantes + decisões do contrato §15 (A23, A31, A35, A36, A37).
# Cada exemplo nomeia a mutação que o quebra.
RSpec.describe "Invariantes do rastreamento de exames (ADR 0036)", type: :request do
  before { exam_city!(fhir: true) }

  let(:unit) { create_unit("UBS Invariantes") }
  let(:doctor) { doctor!(unit) }
  let(:item) { exam_catalog_item! }
  let(:provider) { exam_provider!(token: ExamHelpers::FAKE_TOKEN).tap { |p| ExamProviderItem.find_or_create_by!(exam_provider: p, exam_catalog_item: item) } }
  let(:pair) { exam_patient!(exam_seq!) }

  def schedule!(order, with: provider)
    Exams::Steps.schedule(order: order, actor_user: doctor, params: { provider_id: with.id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "L" })
    order.reload
  end

  def result!(order, critical: false)
    Exams::RegisterResult.call(order: order.reload, source: "unit", file: pdf_file!(user: doctor), released_on: released_on,
                               laboratory_name: "Lab", critical: critical, values: [ { "key" => "hba1c", "value" => "7.7" } ], by_user: doctor)
    order.reload
  end

  def released_on = @released_on ||= Time.zone.today.iso8601

  def full_cycle(patient: pair.first, acknowledge: true, critical: false)
    order = exam_order!(patient: patient, unit: unit, requester: doctor)
    schedule!(order)
    Exams::Steps.collect(order: order.reload, actor_user: doctor)
    result!(order, critical: critical)
    Exams::Acknowledge.call(order: order.reload, by: doctor) if acknowledge
    order.reload
  end

  # Savepoint: cada recusa aborta a transação; o savepoint deixa a próxima viva.
  def attempt(&block) = ApplicationRecord.transaction(requires_new: true, &block)

  def sql(statement) = attempt { ApplicationRecord.connection.execute(statement) }

  def rolled_back = ApplicationRecord.transaction do
    yield
    raise ActiveRecord::Rollback
  end

  def reencrypting(&) = rolled_back { CityEncryption.allowing_reencryption(&) }

  def exam_events = DomainEvent.where("name LIKE 'exam_%'").order(:occurred_at, :created_at, :id)

  # Mutação: tirar o exam_orders_guard, ou gravar o status sem passar pela tabela FLOW.
  it "a situação é derivada da trilha, e a trilha não muda" do
    order = full_cycle
    status = "awaiting_schedule"
    (order.events.map(&:kind) - %w[requested escalated]).each do |kind|
      expect(Exams::Transition::FLOW.fetch(kind)[:from]).to include(status)
      status = Exams::Transition::FLOW.fetch(kind)[:to]
    end
    expect(status).to eq(order.status)
    # (o UPDATE do cache sem evento de outra transação é provado fora da fixture
    # transacional em spec/models/exam_tracking_schema_spec.rb)
    expect { sql("DELETE FROM exam_order_events WHERE exam_order_id = '#{order.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { sql("UPDATE exam_order_events SET kind = 'cancelled' WHERE exam_order_id = '#{order.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { sql("UPDATE exam_orders SET sigtap_code = '0202020380' WHERE id = '#{order.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /identity never changes/)
    expect { sql("DELETE FROM exam_orders WHERE id = '#{order.id}'") }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    expect { sql("UPDATE exam_results SET critical = true WHERE exam_order_id = '#{order.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  # Mutação: tirar o exam_files_guard (ou o ramo "só uma vez" de rota_exam_file_guard).
  it "o arquivo do exame é imutável: bytes nunca mudam, consumed_at só nasce uma vez" do
    file = pdf_file!(user: doctor)
    other = Base64.strict_encode64("%PDF-outro")
    expect { attempt { ExamFile.where(id: file.id).update_all(data: other) } }
      .to raise_error(ActiveRecord::StatementInvalid, /a file never changes/)
    expect { attempt { ExamFile.where(id: file.id).update_all(consumed_at: Time.current, sha256: "0" * 64) } }
      .to raise_error(ActiveRecord::StatementInvalid, /a file never changes/)
    ExamFile.where(id: file.id).update_all(consumed_at: Time.current)
    expect { attempt { ExamFile.where(id: file.id).update_all(consumed_at: 1.day.from_now) } }
      .to raise_error(ActiveRecord::StatementInvalid, /a file never changes/)
    expect { attempt { ExamFile.where(id: file.id).update_all(consumed_at: nil) } }
      .to raise_error(ActiveRecord::StatementInvalid, /a file never changes/)
    expect { attempt { ExamFile.where(id: file.id).delete_all } }.to raise_error(ActiveRecord::StatementInvalid, /consumed file is never deleted/)
    expect(ExamFile.find(file.id).bytes).to eq(ExamHelpers::PDF_BYTES)
  end

  # Mutação: tirar o trigger *_append_only_truncate de uma das quatro tabelas.
  it "TRUNCATE é recusado nas tabelas do rastreamento" do
    full_cycle
    %w[exam_orders exam_order_events exam_results exam_files].each do |table|
      expect { sql("TRUNCATE #{table} CASCADE") }.to raise_error(ActiveRecord::StatementInvalid, /#{table} is append-only: TRUNCATE refused/)
    end
    expect(ExamOrder.count).to eq(1)
  end

  # Mutação: tirar o ramo rota.reencrypting de rota_exam_order_guard/rota_exam_file_guard, ou
  # a lista de colunas de um *_reencryption_only; comparar só parte da linha (coluna não
  # cifrada aceita sob a marca).
  it "re-cifra: só as colunas cifradas, e só em exam_orders/exam_files (e nos eventos/resultados)" do
    order = full_cycle
    cancelled = exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor)
    Exams::Steps.cancel(order: cancelled, reason: "motivo livre da re-cifra", actor_user: doctor)
    event = cancelled.events.find_by!(kind: "cancelled")
    result = order.result
    file = result.pdf_file
    raw = lambda do |table, column, id|
      c = ApplicationRecord.connection
      c.select_value("SELECT #{column} FROM #{table} WHERE id = #{c.quote(id)}")
    end
    # Positivo: a coluna cifrada é regravada de fato (texto cifrado novo) e continua legível.
    { [ "exam_order_events", "reason", event ] => "motivo livre da re-cifra", [ "exam_results", "values", result ] => nil,
      [ "exam_files", "data", file ] => nil }.each do |(table, column, record), plain|
      before = raw.call(table, column, record.id)
      rolled_back do
        CityEncryption.allowing_reencryption { record.encrypt }
        expect(raw.call(table, column, record.id)).not_to eq(before), "#{table}.#{column}"
      end
      expect(raw.call(table, column, record.id)).to eq(before)
      expect(record.reload.public_send(column)).to eq(plain) if plain
    end
    before = raw.call("exam_orders", "requester_name", order.id)
    rolled_back do
      CityEncryption.allowing_reencryption { order.update_columns(requester_name: "Dr. Re-cifra") }
      expect(raw.call("exam_orders", "requester_name", order.id)).not_to eq(before)
    end
    # Negativo: nada além das colunas cifradas muda, mesmo sob a marca.
    expect { reencrypting { order.update_columns(priority: "urgent") } }.to raise_error(ActiveRecord::StatementInvalid, /identity never changes/)
    expect { reencrypting { file.update_columns(sha256: "1" * 64) } }.to raise_error(ActiveRecord::StatementInvalid, /a file never changes/)
    expect { reencrypting { result.update_columns(critical: true) } }
      .to raise_error(ActiveRecord::StatementInvalid, /exam_results is append-only: UPDATE refused/)
    expect { reencrypting { event.update_columns(kind: "authorized") } }
      .to raise_error(ActiveRecord::StatementInvalid, /exam_order_events is append-only: UPDATE refused/)
    # Sem a marca, regravar o cifrado também é recusado.
    expect { attempt { file.update_columns(data: ExamFile.find(file.id).data) } }.to raise_error(ActiveRecord::StatementInvalid, /a file never changes/)
    expect(ExamFile.find(file.id).bytes).to eq(ExamHelpers::PDF_BYTES)
  end

  # Mutação: tirar o exam_provider_id do find no portal, ou dar unit_staff? a exam_provider.
  it "prestador nunca vê guia de outro prestador nem prontuário" do
    order = full_cycle
    other = exam_provider!(name: "Outro Lab")
    lab = staff_with("lab-#{SecureRandom.hex(2)}@lab.com.br", "exam_provider").tap { |u| ExamProviderUser.create!(exam_provider: other, user: u) }
    sign_in_as(lab)
    json_post "/exams/provider/orders/#{order.id}/collect"
    expect(response).to have_http_status(:not_found)
    get "/exams/orders/#{order.id}"
    expect(response).to have_http_status(:not_found)
    get "/clinical_record/patients/#{order.patient_id}"
    expect(response).to have_http_status(:forbidden)
    get "/exams/provider/orders"
    expect(json_body["orders"]).to eq([])
    # Controle positivo: o usuário do prestador certo vê a própria guia.
    mine = staff_with("lab-#{SecureRandom.hex(2)}@lab.com.br", "exam_provider").tap { |u| ExamProviderUser.create!(exam_provider: provider, user: u) }
    sign_in_as(mine)
    get "/exams/provider/orders"
    expect(json_body["orders"].map { |o| o["id"] }).to eq([ order.id ])
  end

  # Mutação: devolver o PDF sem Exams::Release, ou aceitar par declarado.
  it "laudo ao cidadão só pela política e só a par validado" do
    ExamCatalogItem::POLICIES.each do |policy|
      item.update!(release_policy: policy)
      patient, citizen = exam_patient!(exam_seq!)
      order = full_cycle(patient: patient)
      expected = policy != "never_citizen"
      expect(Exams::Release.available?(order.result)).to be(expected), policy
      sign_in_citizen(citizen.phone)
      get "/citizen/exams/#{order.id}/pdf", params: { citizen_id: citizen.id }
      expect(response.status).to eq(expected ? 200 : 404), policy
      expect(response.body.b).to eq(ExamHelpers::PDF_BYTES) if expected
    end
    # Par declarado (mesmo celular): 403 not_verified, corpo exato (contrato §9).
    patient, citizen = exam_patient!(exam_seq!)
    item.update!(release_policy: "immediate")
    order = full_cycle(patient: patient)
    declared = screening_citizen!(exam_seq!).tap { |c| c.update_columns(phone: citizen.phone) }
    expect(declared.verification_level).to eq("declared")
    sign_in_citizen(citizen.phone)
    get "/citizen/exams/#{order.id}/pdf", params: { citizen_id: declared.id }
    expect([ response.status, response.body ]).to eq([ 403, { error: "not_verified" }.to_json ])
  end

  # A23: antes de o cidadão poder saber, `result` é null e o rótulo é o da etapa anterior.
  # A37: never_citizen só mostra "retire na unidade" depois da ciência, e nunca data/PDF.
  # Mutação: trocar `known?` por `true`, ou tirar `status == "acknowledged"` do ramo never_citizen.
  it "resultado do cidadão é null antes da liberação (A23); never_citizen só retire-na-unidade depois da ciência (A37)" do
    patient, citizen = pair
    item.update!(release_policy: "after_acknowledgement")
    order = full_cycle(patient: patient, acknowledge: false)
    sign_in_citizen(citizen.phone)
    get "/citizen/exams", params: { citizen_id: citizen.id }
    row = json_body["exams"].find { |e| e["id"] == order.id }
    expect(row["result"]).to be_nil
    expect(row["status_label"]).to eq("Coletado")
    expect(response.body).not_to include("Resultado disponível")
    get "/citizen/exams/#{order.id}/pdf", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:not_found)

    item.update!(release_policy: "never_citizen")
    get "/citizen/exams", params: { citizen_id: citizen.id }
    expect(json_body["exams"].find { |e| e["id"] == order.id }["result"]).to be_nil
    Exams::Acknowledge.call(order: order.reload, by: doctor)
    get "/citizen/exams", params: { citizen_id: citizen.id }
    row = json_body["exams"].find { |e| e["id"] == order.id }
    expect(row["result"]).to eq("available" => false, "pickup_at_unit" => true, "released_on" => nil, "pdf_available" => false)
    expect(row["status_label"]).to eq("Retire o resultado na sua unidade")
    get "/citizen/exams/#{order.id}/pdf", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:not_found)
  end

  # Mutação: tirar `environments:` do fake_lab no catálogo (Platform::Features), ou a checagem
  # de simulated no FHIR. (O abort de lib/fake_lab/run.rb é guardado pelo spec da Task 15,
  # não por este invariante.)
  it "nenhum fake_lab fora dos ambientes de simulação (catálogo e gate em production; FHIR com fake_lab desligado)" do
    expect(Platform::Features::SIMULATION_ENVS).not_to include("production")
    expect(Platform::Features.catalog(env: "production").map(&:key)).not_to include("fake_lab")
    expect(Platform::Features.catalog(env: "development").map(&:key)).to include("fake_lab")
    expect(Exams::Gate.fake_lab_usable?(Current.city, env: "production")).to be(false)
    expect { Platform::Features.set!(city: Current.city, key: "fake_lab", enabled: true, maintainer: ledi_maintainer!, env: "production") }
      .to raise_error(Platform::Features::UnknownFeature)
    provider.update!(simulated: true)
    Platform::Features.set!(city: Current.city, key: "fake_lab", enabled: false, maintainer: ledi_maintainer!)
    post "/fhir/DiagnosticReport", params: "{}", headers: { "CONTENT_TYPE" => "application/fhir+json", "Authorization" => "Bearer #{ExamHelpers::FAKE_TOKEN}" }
    expect(JSON.parse(response.body)).to eq("error" => "feature_disabled", "feature" => "fake_lab")
  end

  # Mutação: pôr valor, CPF, nome, motivo ou token num evento; guardar o token em claro.
  it "eventos só com ids e códigos; token FHIR só como hash" do
    token = Exams::RotateFhirToken.call(provider: provider).payload[:token]
    order = full_cycle(critical: true)
    free_text = "Paciente relatou segredo-de-justica-xyz"
    Exams::Steps.cancel(order: exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor),
                        reason: free_text, actor_user: doctor)
    expect(DomainEvent.where(name: "exam_order.cancelled").count).to eq(1)
    allowed = %w[exam_order_id exam_result_id exam_provider_id origin priority source critical by_team reason patient_id user_id]
    expect(exam_events.count).to be > 3
    exam_events.each do |event|
      expect(event.payload.keys - allowed).to eq([]), event.name
      expect(event.payload.to_json).not_to include("7.7", order.patient.cpf, order.patient.display_name, free_text, token)
    end
    escalation = DomainEvent.where(name: "exam_order.escalated").pluck(:payload).map { |p| p["reason"] }
    expect(escalation).to eq(%w[critical])
    expect(escalation - ExamOrderEvent::ESCALATION_REASONS).to eq([])
    expect(ExamProvider.where(id: provider.id).pluck(:fhir_token_digest).first).to eq(Digest::SHA256.hexdigest(token))
    expect(ApplicationRecord.connection.select_all("SELECT * FROM exam_providers").to_a.to_s).not_to include(token)
  end

  # A31. Mutação: tirar idx_exam_order_events_escalation_once, ou o `escalated_for?` de Exams::Escalate.
  it "no máximo um escalated por motivo e por pedido (A31)" do
    order = exam_order!(patient: pair.first, unit: unit, requester: doctor)
    now = Time.current
    expect(Exams::Escalate.call(order: order, reason: "overdue", now: now).payload[:escalated]).to be(true)
    expect(Exams::Escalate.call(order: order, reason: "overdue", now: now).payload[:escalated]).to be(false)
    expect(Exams::Escalate.call(order: order, reason: "critical", now: now).payload[:escalated]).to be(true)
    expect(order.events.where(kind: "escalated").pluck(:escalation_reason)).to match_array(%w[overdue critical])
    expect { attempt { ExamOrderEvent.create!(exam_order: order, kind: "escalated", escalation_reason: "critical", occurred_at: now) } }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_exam_order_events_escalation_once/)
  end

  # A35. Mutação: gravar só o prestador no portal (perde o funcionário), ou trocar o actor do
  # JSON para o usuário; ou dar actor ao escalated do sistema.
  it "quem agiu: portal grava prestador e funcionário; FHIR só o prestador; system sem ator; JSON mostra o prestador (A35)" do
    lab = staff_with("lab-#{SecureRandom.hex(2)}@lab.com.br", "exam_provider").tap { |u| ExamProviderUser.create!(exam_provider: provider, user: u) }
    portal = exam_order!(patient: pair.first, unit: unit, requester: doctor)
    schedule!(portal)
    sign_in_as(lab)
    json_post "/exams/provider/orders/#{portal.id}/collect"
    expect(response).to have_http_status(:ok)
    event = portal.reload.events.find_by!(kind: "collected")
    expect([ event.actor_provider_id, event.actor_user_id ]).to eq([ provider.id, lab.id ])

    # FHIR: só o prestador.
    fhir_item = exam_catalog_item!(sigtap_code: "0202020380", result_fields: [ { "key" => "hb", "label" => "Hemoglobina", "unit" => "g/dL", "loinc" => "718-7" } ])
    ExamProviderItem.find_or_create_by!(exam_provider: provider, exam_catalog_item: fhir_item)
    fhir = exam_order!(patient: pair.first, unit: unit, requester: doctor, sigtap_code: fhir_item.sigtap_code)
    schedule!(fhir)
    body = JSON.parse(File.read(Rails.root.join("spec/fixtures/exams/diagnostic-report-hemograma.json")))
    body["basedOn"][0]["identifier"]["value"] = fhir.short_code
    body["subject"]["identifier"]["value"] = pair.first.cpf
    body["issued"] = Time.current.iso8601
    post "/fhir/DiagnosticReport", params: body.to_json, headers: { "CONTENT_TYPE" => "application/fhir+json", "Authorization" => "Bearer #{ExamHelpers::FAKE_TOKEN}" }
    expect(response).to have_http_status(:created)
    fhir_event = fhir.reload.events.find_by!(kind: "resulted")
    expect([ fhir_event.actor_provider_id, fhir_event.actor_user_id ]).to eq([ provider.id, nil ])

    # system: sem ator nenhum.
    Exams::Escalate.call(order: portal, reason: "overdue", now: Time.current)
    system_event = portal.events.find_by!(kind: "escalated", escalation_reason: "overdue")
    expect([ system_event.actor_provider_id, system_event.actor_user_id ]).to eq([ nil, nil ])

    # Quem lê na unidade vê o prestador como ator, nunca a pessoa do laboratório.
    sign_in_as(doctor)
    get "/exams/orders/#{portal.id}"
    expect(response).to have_http_status(:ok)
    actors = json_body["events"].select { |e| e["kind"] == "collected" }.map { |e| e["actor"] }
    expect(actors).to eq([ { "type" => "provider", "name" => provider.name } ])
    expect(response.body).not_to include(lab.email_address)
  end

  # A36. Mutação: aceitar `amended`, ou tirar o 409 do identificador em outra guia.
  it "FHIR: amended recusado e identificador em outra guia é conflito (A36)" do
    fhir_item = exam_catalog_item!(sigtap_code: "0202020380", result_fields: [ { "key" => "hb", "label" => "Hemoglobina", "unit" => "g/dL", "loinc" => "718-7" } ])
    ExamProviderItem.find_or_create_by!(exam_provider: provider, exam_catalog_item: fhir_item)
    patient = pair.first
    first = schedule!(exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: fhir_item.sigtap_code))
    second = schedule!(exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: fhir_item.sigtap_code))
    send_report = lambda do |order, **over|
      body = JSON.parse(File.read(Rails.root.join("spec/fixtures/exams/diagnostic-report-hemograma.json")))
      body["basedOn"][0]["identifier"]["value"] = order.short_code
      body["subject"]["identifier"]["value"] = patient.cpf
      body["issued"] = Time.current.iso8601
      post "/fhir/DiagnosticReport", params: body.merge(over.transform_keys(&:to_s)).to_json,
                                     headers: { "CONTENT_TYPE" => "application/fhir+json", "Authorization" => "Bearer #{ExamHelpers::FAKE_TOKEN}" }
    end
    files = ExamFile.count
    send_report.call(first, status: "amended")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "amendment_not_supported" } ])
    expect([ first.reload.status, ExamFile.count ]).to eq([ "scheduled", files ])
    send_report.call(first)
    expect(response).to have_http_status(:created)
    send_report.call(second)
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "identifier_conflict" } ])
    expect(second.reload.status).to eq("scheduled")
  end
end
