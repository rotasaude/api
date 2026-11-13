require "rails_helper"

# Contrato §4 (ADR 0035): o histórico do cidadão. Par validado vê a pessoa
# inteira (sem texto clínico livre); par declarado vê só triagens e
# agendamentos dele. Review Focus 3: a família no mesmo celular.
RSpec.describe "Histórico do cidadão", type: :request do
  before { timeline_city!(documents: true); ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit("UBS Centro") }
  let(:doctor) { doctor!(unit) }
  let(:mother) { verified_citizen!(111, social_name: "Dona Lu") }
  let!(:child) { Citizen.create!(cpf: "39053344705", phone: mother.phone, verification_level: "declared") }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: mother) }
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  it "sem sessão: 401; interruptor desligado: 403 feature_disabled" do
    get "/citizen/history", params: { citizen_id: mother.id }
    expect(status_and_error).to eq([ 401, "unauthenticated" ])
    sign_in_citizen(mother.phone)
    Platform::Features.set!(city: Current.city, key: "patient_timeline", enabled: false, maintainer: ledi_maintainer!)
    get "/citizen/history", params: { citizen_id: mother.id }
    expect([ response.status, body["error"], body["feature"] ]).to eq([ 403, "feature_disabled", "patient_timeline" ])
  end

  it "par validado: a pessoa inteira, documento com PDF e código, trilha citizen, sem texto livre" do
    document = raw_document!(consultation: consultation, kind: "sick_note", issue_mode: "paper")
    other_phone_pair = Citizen.create!(cpf: mother.cpf, phone: "+5541988880001", verification_level: "verified",
                                       patient_id: consultation.patient_id)
    completed_web_triage_for(mother) # a da consulta já existe: com a do outro telefone, são três
    completed_web_triage_for(other_phone_pair)
    sign_in_citizen(mother.phone)
    get "/citizen/history", params: { citizen_id: mother.id }
    expect(response).to have_http_status(:ok)
    expect(body.slice("verified", "partial")).to eq("verified" => true, "partial" => false)
    kinds = body["entries"].map { |e| e["kind"] }
    expect(kinds).to include("consultation", "clinical_document", "attendance", "triage")
    expect(kinds.count("triage")).to eq(3)
    doc = body["entries"].find { |e| e["kind"] == "clinical_document" }
    expect(doc["document"]).to eq("id" => document.id, "short_code" => document.short_code,
                                  "verification_url" => document.verification_url, "downloadable" => true)
    expect(body["entries"].first.keys).to include("professional_name")
    expect(body["entries"].first.keys).not_to include("detail_ref", "professional")
    expect(response.body).not_to include("Refere sede", "Metformina", "T90", "Diabetes")
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).last.payload)
      .to include("access" => "citizen", "user_id" => nil, "person_ref" => "patient:#{consultation.patient_id}")
  end

  it "família no mesmo celular: o declarado vê só triagens e agendamentos dele; de outro telefone, 404 (Review Focus 3)" do
    consultation
    completed_web_triage_for(child)
    stranger = verified_citizen!(112)
    sign_in_citizen(mother.phone)
    get "/citizen/history", params: { citizen_id: child.id }
    expect(body["verified"]).to be(false)
    expect(body["entries"].map { |e| e["kind"] }.uniq).to eq(%w[triage])
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).last.payload["person_ref"]).to eq("citizen:#{child.id}")
    get "/citizen/history", params: { citizen_id: stranger.id }
    expect(status_and_error).to eq([ 404, "not_found" ])
    get "/citizen/history"
    expect(status_and_error).to eq([ 404, "not_found" ])
  end

  it "PDF: só documento da própria pessoa, não cancelado e baixável" do
    paper = raw_document!(consultation: consultation, kind: "sick_note", issue_mode: "paper")
    unsigned = raw_document!(consultation: consultation, kind: "sick_note", issue_mode: "digital")
    strangers = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(113))
    foreign = raw_document!(consultation: strangers, kind: "sick_note", issue_mode: "paper")
    sign_in_citizen(mother.phone)
    get "/citizen/documents/#{paper.id}/pdf", params: { citizen_id: mother.id }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.headers["Cache-Control"]).to include("no-store")
    [ unsigned.id, foreign.id, SecureRandom.uuid, "nao-e-uuid" ].each do |id|
      get "/citizen/documents/#{id}/pdf", params: { citizen_id: mother.id }
      expect(status_and_error).to eq([ 404, "not_found" ]), id
    end
    paper.update_columns(status: "cancelled", cancelled_at: Time.current, cancel_reason: "emitido por engano",
                         cancelled_by_user_id: doctor.id)
    get "/citizen/documents/#{paper.id}/pdf", params: { citizen_id: mother.id }
    expect(status_and_error).to eq([ 404, "not_found" ])
    get "/citizen/documents/#{paper.id}/pdf", params: { citizen_id: child.id }
    expect(status_and_error).to eq([ 403, "not_verified" ])
  end

  it "PDF: registro da Notificação e clinical_documents desligado dão 404; anexo; teto de 30 por 10 min dá 429" do
    paper = raw_document!(consultation: consultation, kind: "sick_note", issue_mode: "paper")
    notification = raw_document!(consultation: consultation, kind: "controlled_notification_record", issue_mode: "paper")
    sign_in_citizen(mother.phone)
    get "/citizen/documents/#{notification.id}/pdf", params: { citizen_id: mother.id }
    expect(status_and_error).to eq([ 404, "not_found" ])

    get "/citizen/documents/#{paper.id}/pdf", params: { citizen_id: mother.id }
    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Disposition"]).to start_with("attachment")

    Platform::Features.set!(city: Current.city, key: "clinical_documents", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    get "/citizen/documents/#{paper.id}/pdf", params: { citizen_id: mother.id }
    expect(status_and_error).to eq([ 404, "not_found" ])

    # O cache de teste é :null_store, que nunca conta; um real só aqui.
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    30.times { get "/citizen/documents/#{SecureRandom.uuid}/pdf", params: { citizen_id: mother.id } }
    expect(response).to have_http_status(:not_found)
    get "/citizen/documents/#{SecureRandom.uuid}/pdf", params: { citizen_id: mother.id }
    expect(status_and_error).to eq([ 429, "too_many_requests" ])
  end

  it "cursor e kinds inválidos: 422; kinds recorta só dentro do que a pessoa pode ver" do
    consultation
    completed_web_triage_for(child)
    sign_in_citizen(mother.phone)
    get "/citizen/history", params: { citizen_id: mother.id, before: "lixo" }
    expect(status_and_error).to eq([ 422, "invalid_cursor" ])
    get "/citizen/history", params: { citizen_id: mother.id, kinds: %w[nope] }
    expect(status_and_error).to eq([ 422, "invalid_kinds" ])
    get "/citizen/history", params: { citizen_id: mother.id, kinds: %w[consultation], limit: 1 }
    expect(body["entries"].map { |e| e["kind"] }).to eq(%w[consultation])
    get "/citizen/history", params: { citizen_id: child.id, kinds: %w[consultation triage] }
    expect(body["entries"].map { |e| e["kind"] }.uniq).to eq(%w[triage])
  end

  # 27a (H7): a dispensação é só do profissional; o pedido do cidadão por
  # kinds[]=dispensation é aceito (kind válido) e recortado para nada.
  it "dispensação nunca entra no histórico do cidadão, nem pedida por kinds[]" do
    import_test_catalog!
    admin = pharmacy_admin!
    document = pharmacy_prescription!(consultation: consultation)
    lot = StockLot.create!(catalog_item_id: losartana.id, catmat_code: losartana.catmat_code, lot_number: "LOTE-C", expires_on: Time.zone.today + 90,
                           dispensing_unit: "comprimido", created_by_user: admin)
    dispensation = Dispensation.create!(stock_location: unit_location!, patient: consultation.patient, clinical_document: document,
                                        dispensed_by_user: admin, dispensed_by_role: "pharmacist", dispensed_at: Time.current)
    DispensationItem.create!(dispensation: dispensation, prescription_item: document.prescription_items.first, stock_lot: lot,
                             catalog_item_id: losartana.id, quantity: 30)
    sign_in_citizen(mother.phone)
    get "/citizen/history", params: { citizen_id: mother.id, kinds: %w[dispensation] }
    expect([ response.status, body["entries"] ]).to eq([ 200, [] ])
    get "/citizen/history", params: { citizen_id: mother.id }
    expect(response).to have_http_status(:ok)
    expect(body["entries"].map { |e| e["kind"] }).to include("consultation")
    expect(body["entries"].map { |e| e["kind"] }).not_to include("dispensation")
    expect(response.body).not_to include("dispensation", dispensation.id, losartana.label)
  end

  # Módulo 24b (contrato §12, Q22, Q23): a visita domiciliar chega ao wpda sem
  # kinds[] (Timeline::KINDS), só a realizada e não retirada, na forma fixa e
  # com occurred_at ao meio-dia local do dia da folha. Par só declarado não vê;
  # com home_visits desligado, a realizada continua (registro retido).
  describe "visita domiciliar (24b)" do
    let!(:visit_city) { home_visit_city! }
    let(:team) { registry_team! }
    let(:agent) { field_agent!(team: team) }
    let(:patient) { registry_patient! }
    let(:phone) { "+5541988824017" }
    let!(:pair) { Citizen.create!(cpf: patient.cpf, phone: phone, verification_level: "verified", patient_id: patient.id) }
    let(:note) { "MARCADOR-OBS-24B" }

    def sheet!(on) = home_visit_day!(agent: agent, team: team, day: on)

    def visit!(sheet, hour:, outcome: 1, **over)
      reason = outcome == 1 ? { has_reason: true, reasons: [ 29, 5 ] } : {}
      home_visit!(day: sheet, occurred_at: sheet.day.in_time_zone.change(hour: hour), subject: "resident", patient: patient,
                  outcome: outcome, note: note, **reason, **over)
    end

    def visits_in_history
      get "/citizen/history", params: { citizen_id: pair.id }
      expect(response).to have_http_status(:ok)
      body["entries"].select { |entry| entry["kind"] == "home_visit" }
    end

    it "sem kinds[] traz só a realizada, igual à forma do contrato chave por chave, ao meio-dia local (Q22)" do
      on = Date.current - 2
      sheet = sheet!(on)
      done = visit!(sheet, hour: 16, measurements: { "weight_kg" => 70.5 })
      visit!(sheet, hour: 10, outcome: 2)
      visit!(sheet, hour: 11, outcome: 3)
      visit!(sheet, hour: 9).update!(withdrawn_at: Time.current, withdrawn_by_user: agent, withdrawal_reason: "Registrei no morador errado")
      sign_in_citizen(phone)

      entries = visits_in_history

      expect(entries).to eq([ { "id" => "home_visit:#{done.id}", "kind" => "home_visit", "occurred_at" => "#{on.iso8601}T12:00:00-03:00",
                                "unit" => nil, "professional_name" => nil, "title" => "Visita do agente de saúde", "summary" => nil,
                                "status" => nil, "document" => nil } ])
      expect(entries.sole.keys).to eq(%w[id kind occurred_at unit professional_name title summary status document])
      expect(response.body).not_to include(note, "Gestante", "Visita periódica", "Registrei no morador errado", "T16:00", "T19:00",
                                           agent.professional.professional_name)
    end

    it "paginação do cidadão com visitas em dias vizinhos: nenhuma pulada nem repetida" do
      d1 = Date.current - 1
      d2 = Date.current - 2
      d3 = Date.current - 3
      newest = visit!(sheet!(d1), hour: 7)
      middle = sheet!(d2)
      pair_of_day = [ visit!(middle, hour: 8), visit!(middle, hour: 19) ].sort_by(&:id)
      oldest = visit!(sheet!(d3), hour: 23)
      sign_in_citizen(phone)

      seen = []
      before = nil
      loop do
        get "/citizen/history", params: { citizen_id: pair.id, kinds: %w[home_visit], limit: 1, before: before }.compact
        expect(response).to have_http_status(:ok)
        seen.concat(body["entries"].map { |entry| [ entry["id"], entry["occurred_at"] ] })
        before = body["next_before"]
        break unless before
      end

      expect(seen).to eq([ [ "home_visit:#{newest.id}", "#{d1.iso8601}T12:00:00-03:00" ],
                           *pair_of_day.map { |visit| [ "home_visit:#{visit.id}", "#{d2.iso8601}T12:00:00-03:00" ] },
                           [ "home_visit:#{oldest.id}", "#{d3.iso8601}T12:00:00-03:00" ] ])
    end

    it "par só declarado não vê a visita (Q23)" do
      visit!(sheet!(Date.current - 1), hour: 9)
      declared_phone = "+5541988824018"
      declared = Citizen.create!(cpf: patient.cpf, phone: declared_phone, verification_level: "declared")
      sign_in_citizen(declared_phone)

      get "/citizen/history", params: { citizen_id: declared.id }
      expect(response).to have_http_status(:ok)
      expect(body["verified"]).to be(false)
      expect(body["entries"].map { |entry| entry["kind"] }).not_to include("home_visit")
      get "/citizen/history", params: { citizen_id: declared.id, kinds: %w[home_visit] }
      expect([ response.status, body["entries"] ]).to eq([ 200, [] ])
    end

    it "com home_visits desligado a visita realizada continua no histórico (Q23)" do
      done = visit!(sheet!(Date.current - 1), hour: 9)
      Platform::Features.set!(city: visit_city, key: HomeVisits::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      sign_in_citizen(phone)

      expect(visits_in_history.map { |entry| entry["id"] }).to eq([ "home_visit:#{done.id}" ])
    end
  end
end
