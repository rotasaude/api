require "rails_helper"

# Módulo 32b (ADR 0050; contrato §4, §10 e §12 Q2, Q3; plano, Desvios 1 e 2):
# o mapa da observação (GET /urgency/observation, polling sem trilha e sem
# texto clínico; lê a recepção de qualquer UPA e quem checa medicação na UPA,
# o técnico 3222 inclusive), a entrada e a troca de leito (POST
# /urgency/encounters/:id/observation, só 2235*/225*) e a saída sem desfecho
# (POST …/observation/end). Os eventos levam só encounter_id e stay_id. A
# corrida de dois pacientes pelo mesmo leito está em
# spec/commands/urgency/start_observation_concurrency_spec.rb (Review Focus 1).
RSpec.describe "Urgência — observação", type: :request do
  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:doctor) { observation_doctor!(upa) }
  let(:nurse) { observation_nurse!(upa) }
  let(:bed) { urgency_bed!(upa, label: "OBS 01") }
  after { Current.reset }

  def board(unit = upa, params = {}) = get("/urgency/observation", params: { health_unit_id: unit.id, **params })
  def enter(encounter, **body) = json_post("/urgency/encounters/#{encounter.id}/observation", body)
  def leave(encounter, **body) = json_post("/urgency/encounters/#{encounter.id}/observation/end", body)
  def events(name, encounter) = DomainEvent.where(name: name).where("payload->>'encounter_id' = ?", encounter.id)
  def trail = DomainEvent.where(name: "clinical_record.viewed")

  def expect_refusal(status, error, path = nil)
    expect(response).to have_http_status(status)
    expect(json_body["error"]).to eq(error)
    expect(json_body["path"]).to eq(path) if path
  end

  describe "entrada, troca e saída" do
    it "entrada → 201 com o detalhe; o evento observation_started só com encounter_id e stay_id; o mapa mostra a estadia" do
      encounter = in_care_encounter!(upa)
      sign_in_as(doctor)
      enter(encounter, bed_id: bed.id)
      expect(response).to have_http_status(:created)
      expect(json_body["encounter"]).to include("id" => encounter.id, "state" => "in_care")
      stay = UrgencyBedStay.open_stays.find_by!(urgency_encounter_id: encounter.id)
      expect(stay).to have_attributes(urgency_bed_id: bed.id, health_unit_id: upa.id, started_by_user_id: doctor.id)
      expect(events("urgency.observation_started", encounter).sole.payload)
        .to eq("encounter_id" => encounter.id, "stay_id" => stay.id)
      expect(events("urgency.observation_ended", encounter)).to be_empty

      board
      expect(response).to have_http_status(:ok)
      expect(json_body["beds"].sole).to include("bed_id" => bed.id, "label" => "OBS 01", "active" => true)
      expect(json_body.dig("beds", 0, "stay")).to include("stay_id" => stay.id, "encounter_id" => encounter.id, "hours" => 0,
                                                          "alert" => nil, "ticket" => encounter.attendance.ticket)
      expect(json_body["waiting_bed"]).to eq([])
    end

    it "a enfermagem 2235 também põe no leito" do
      sign_in_as(nurse)
      enter(in_care_encounter!(upa), bed_id: bed.id)
      expect(response).to have_http_status(:created)
    end

    it "troca de leito → fecha com bed_change e abre a nova no mesmo instante; dois eventos; o leito antigo fica livre no mapa" do
      encounter = in_care_encounter!(upa)
      other_bed = urgency_bed!(upa, label: "OBS 02")
      old = observed!(encounter, bed: bed)
      sign_in_as(doctor)
      enter(encounter, bed_id: other_bed.id)
      expect(response).to have_http_status(:created)
      new_stay = UrgencyBedStay.open_stays.find_by!(urgency_encounter_id: encounter.id)
      expect(old.reload).to have_attributes(end_kind: "bed_change", ended_by_user_id: doctor.id, ended_at: new_stay.started_at)
      expect(events("urgency.observation_ended", encounter).sole.payload).to eq("encounter_id" => encounter.id, "stay_id" => old.id)
      expect(events("urgency.observation_started", encounter).map(&:payload))
        .to include("encounter_id" => encounter.id, "stay_id" => new_stay.id)

      board
      stays = json_body["beds"].to_h { |b| [ b["label"], b["stay"] ] }
      expect(stays["OBS 01"]).to be_nil
      expect(stays["OBS 02"]).to include("stay_id" => new_stay.id)
    end

    it "saída sem desfecho → 200, fecha com observation_ended e publica o evento; a segunda vez → 422 not_in_observation" do
      encounter = in_care_encounter!(upa)
      stay = observed!(encounter, bed: bed)
      sign_in_as(doctor)
      leave(encounter)
      expect(response).to have_http_status(:ok)
      expect(json_body["encounter"]).to include("id" => encounter.id, "state" => "in_care")
      expect(stay.reload).to have_attributes(end_kind: "observation_ended", ended_by_user_id: doctor.id)
      expect(events("urgency.observation_ended", encounter).sole.payload).to eq("encounter_id" => encounter.id, "stay_id" => stay.id)

      board
      expect(json_body.dig("beds", 0, "stay")).to be_nil
      expect(json_body["waiting_bed"].map { |w| w["encounter_id"] }).to eq([ encounter.id ])

      leave(encounter)
      expect_refusal(:unprocessable_entity, "not_in_observation")
    end

    # Task 12 (contrato 32b §4, §5 e §12 Q4, Q9): a saída sem desfecho não
    # mexe na prescrição; o desfecho fecha a estadia com `outcome`, encerra a
    # prescrição e tira o paciente do mapa (nem no leito, nem em waiting_bed).
    it "a saída sem desfecho mantém a prescrição ativa; o desfecho depois fecha a nova estadia com outcome e esvazia o mapa" do
      ciap2_release!
      cid10_release!
      sigtap_release!
      import_test_catalog!
      losartana = catalog_item(268_856)
      encounter = in_care_encounter!(upa)
      urgency_consultation!(encounter, doctor: doctor)
      first = observed!(encounter, bed: bed)
      item = { "catalog_item_id" => losartana.id, "dose" => "50", "dose_unit" => "mg", "route" => "oral",
               "frequency" => { "kind" => "interval", "interval_hours" => 8 } }
      prescription = Urgency::IssuePrescription.call(encounter: encounter.reload, items: [ item ], by: doctor,
                                                     catalog: { losartana.id => losartana }).payload.fetch(:prescription)
      sign_in_as(doctor)
      leave(encounter)
      expect(response).to have_http_status(:ok)
      expect(first.reload.end_kind).to eq("observation_ended")
      expect(prescription.reload.status).to eq("active")

      second = observed!(encounter, bed: bed)
      finalized_urgency!(encounter, doctor: doctor)
      result = Urgency::RecordOutcome.call(encounter: encounter.reload, attrs: { "kind" => "discharged" }, by: doctor)
      expect(result).to be_ok
      expect(second.reload).to have_attributes(end_kind: "outcome", ended_at: result.payload[:outcome].recorded_at)
      expect(prescription.reload.status).to eq("ended")
      expect(events("urgency.observation_ended", encounter).map { |e| e.payload["stay_id"] }).to contain_exactly(first.id, second.id)

      board
      expect(json_body.dig("beds", 0, "stay")).to be_nil
      expect(json_body["waiting_bed"]).to eq([])
    end
  end

  describe "recusas da entrada" do
    before { sign_in_as(doctor) }

    it "classificado e não chamado → 422 not_in_care; encontro fechado → 409 encounter_closed" do
      classified = arrived!(upa).tap { |e| classified!(e, color: "green", by: nurse) }
      enter(classified, bed_id: bed.id)
      expect_refusal(:unprocessable_entity, "not_in_care")

      closed = arrived!(upa)
      outcome = Urgency::RecordOutcome.call(encounter: closed, attrs: { "kind" => "left_without_care" }, by: upa_reception!)
      expect(outcome).to be_ok
      enter(closed, bed_id: bed.id)
      expect_refusal(:conflict, "encounter_closed")
      expect(UrgencyBedStay.where(urgency_encounter_id: [ classified.id, closed.id ])).to be_empty
    end

    it "leito de outra UPA, inativo ou inexistente → 422 bed_unavailable em bed_id" do
      encounter = in_care_encounter!(upa)
      [ urgency_bed!(upa!, label: "FORA"), urgency_bed!(upa, label: "OBS 99", active: false) ].each do |unavailable|
        enter(encounter, bed_id: unavailable.id)
        expect_refusal(:unprocessable_entity, "bed_unavailable", "bed_id")
      end
      enter(encounter, bed_id: SecureRandom.uuid)
      expect_refusal(:unprocessable_entity, "bed_unavailable", "bed_id")
      expect(UrgencyBedStay.where(urgency_encounter_id: encounter.id)).to be_empty
    end

    it "bed_id malformado ou ausente, chave desconhecida e o mesmo leito da estadia aberta → 422 invalid_request com o path" do
      encounter = in_care_encounter!(upa)
      enter(encounter, bed_id: "nao-e-uuid")
      expect_refusal(:unprocessable_entity, "invalid_request", "bed_id")
      expect(json_body["problems"]).to eq([ { "path" => "bed_id", "error" => "invalid_request" } ])
      enter(encounter)
      expect_refusal(:unprocessable_entity, "invalid_request", "bed_id")
      enter(encounter, bed_id: bed.id, note: "x")
      expect_refusal(:unprocessable_entity, "invalid_request", "note")
      json_post("/urgency/encounters/#{encounter.id}/observation?cpf=1", { bed_id: bed.id })
      expect_refusal(:unprocessable_entity, "invalid_request", "cpf")

      observed!(encounter, bed: bed)
      enter(encounter, bed_id: bed.id)
      expect_refusal(:unprocessable_entity, "invalid_request", "bed_id")
      expect(UrgencyBedStay.where(urgency_encounter_id: encounter.id).count).to eq(1)
    end

    it "leito ocupado por outro paciente → 409 bed_taken, nada muda (nem a estadia aberta do que pedia a troca)" do
      occupant = in_care_encounter!(upa)
      observed!(occupant, bed: bed)
      encounter = in_care_encounter!(upa)
      enter(encounter, bed_id: bed.id)
      expect_refusal(:conflict, "bed_taken")

      own = observed!(encounter, bed: urgency_bed!(upa, label: "OBS 02"))
      enter(encounter, bed_id: bed.id)
      expect_refusal(:conflict, "bed_taken")
      expect(own.reload).to be_open
      expect(events("urgency.observation_ended", encounter)).to be_empty
    end

    it "Q15: expected_stay_id null declara entrada; com estadia aberta (tela velha) → 409 observation_changed e nada muda" do
      encounter = in_care_encounter!(upa)
      other_bed = urgency_bed!(upa, label: "OBS 02")
      own = observed!(encounter, bed: other_bed)
      sign_in_as(doctor)
      expect { enter(encounter, bed_id: bed.id, expected_stay_id: nil) }
        .not_to(change { DomainEvent.where("name LIKE 'urgency.observation_%'").count })
      expect_refusal(:conflict, "observation_changed")
      expect(own.reload).to be_open
      expect(UrgencyBedStay.where(urgency_encounter_id: encounter.id).count).to eq(1)

      fresh = in_care_encounter!(upa)
      enter(fresh, bed_id: bed.id, expected_stay_id: nil)
      expect(response).to have_http_status(:created)
    end

    it "Q15: expected_stay_id com o id da estadia aberta troca; com outro id (ou sem estadia aberta) → 409; malformado → 422" do
      encounter = in_care_encounter!(upa)
      other_bed = urgency_bed!(upa, label: "OBS 02")
      third_bed = urgency_bed!(upa, label: "OBS 03")
      first = observed!(encounter, bed: bed)
      sign_in_as(nurse)
      enter(encounter, bed_id: other_bed.id, expected_stay_id: "nao-e-uuid")
      expect_refusal(:unprocessable_entity, "invalid_request", "expected_stay_id")
      enter(encounter, bed_id: other_bed.id, expected_stay_id: SecureRandom.uuid)
      expect_refusal(:conflict, "observation_changed")
      expect(first.reload).to be_open

      enter(encounter, bed_id: other_bed.id, expected_stay_id: first.id)
      expect(response).to have_http_status(:created)
      second = UrgencyBedStay.open_stays.find_by!(urgency_encounter_id: encounter.id)
      expect(second.urgency_bed_id).to eq(other_bed.id)

      enter(encounter, bed_id: third_bed.id, expected_stay_id: first.id) # a estadia velha, de uma tela que não releu o mapa
      expect_refusal(:conflict, "observation_changed")
      expect(second.reload).to be_open

      leave(encounter)
      expect(response).to have_http_status(:ok)
      enter(encounter, bed_id: third_bed.id, expected_stay_id: second.id)
      expect_refusal(:conflict, "observation_changed")
      expect(UrgencyBedStay.open_stays.where(urgency_encounter_id: encounter.id)).to be_empty
    end

    it "encontro inexistente ou malformado → 404" do
      enter(Struct.new(:id).new(SecureRandom.uuid), bed_id: bed.id)
      expect(response).to have_http_status(:not_found)
      json_post("/urgency/encounters/nao-e-uuid/observation", { bed_id: bed.id })
      expect(response).to have_http_status(:not_found)
    end

    it "saída: chave desconhecida → 422 com o path; encontro fechado → 409 encounter_closed" do
      encounter = in_care_encounter!(upa)
      observed!(encounter, bed: bed)
      leave(encounter, reason: "x")
      expect_refusal(:unprocessable_entity, "invalid_request", "reason")
      expect(UrgencyBedStay.open_stays.where(urgency_encounter_id: encounter.id).count).to eq(1)

      closed = arrived!(upa)
      Urgency::RecordOutcome.call(encounter: closed, attrs: { "kind" => "left_without_care" }, by: upa_reception!)
      leave(closed)
      expect_refusal(:conflict, "encounter_closed")
    end
  end

  describe "quem lê o mapa e quem põe no leito (Q2, Q3)" do
    it "o técnico 3222 lê o mapa e não entra nem tira o paciente do leito (403 cbo_not_allowed)" do
      encounter = in_care_encounter!(upa)
      observed!(encounter, bed: bed)
      sign_in_as(upa_nurse!(upa, cbo: "322205"))
      board
      expect(response).to have_http_status(:ok)
      enter(in_care_encounter!(upa), bed_id: urgency_bed!(upa, label: "OBS 02").id)
      expect_refusal(:forbidden, "cbo_not_allowed")
      leave(encounter)
      expect_refusal(:forbidden, "cbo_not_allowed")
      expect(UrgencyBedStay.open_stays.where(health_unit_id: upa.id).count).to eq(1)
    end

    it "a recepção lê o mapa de qualquer UPA e não põe no leito (403 missing_role)" do
      sign_in_as(upa_reception!)
      board(upa!)
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("beds" => [], "waiting_bed" => [])
      enter(in_care_encounter!(upa), bed_id: bed.id)
      expect_refusal(:forbidden, "missing_role")
    end

    it "médico de outra UPA → 403 missing_link; quem perdeu o vínculo → 403 missing_link, nunca 404; sem papel → missing_role" do
      encounter = in_care_encounter!(upa)
      sign_in_as(upa_doctor!(upa!))
      board
      expect_refusal(:forbidden, "missing_link")
      enter(encounter, bed_id: bed.id)
      expect_refusal(:forbidden, "missing_link")

      doctor.professional.links.active.sole.update!(ended_at: Time.current, ended_by_user: urgency_admin!)
      sign_in_as(doctor)
      board
      expect_refusal(:forbidden, "missing_link")
      enter(encounter, bed_id: bed.id)
      expect_refusal(:forbidden, "missing_link")
      leave(encounter)
      expect_refusal(:forbidden, "missing_link")

      sign_in_as(staff_with("sem-papel-#{SecureRandom.hex(3)}@cidade.gov.br", "billing_clerk"))
      board
      expect_refusal(:forbidden, "missing_role")
    end
  end

  describe "o mapa" do
    before { sign_in_as(nurse) }

    it "não grava clinical_record.viewed, não traz texto clínico e lista em waiting_bed quem está em atendimento sem leito" do
      waiting = in_care_encounter!(upa)
      observed!(in_care_encounter!(upa), bed: bed)
      expect { board }.not_to change(trail, :count)
      expect(response).to have_http_status(:ok)
      expect(json_body["waiting_bed"].map { |w| w["encounter_id"] }).to eq([ waiting.id ])
      expect(json_body["waiting_bed"].first.keys).to match_array(%w[encounter_id ticket patient called_at])
      expect(json_body.dig("beds", 0, "stay").keys).to match_array(%w[stay_id encounter_id ticket patient started_at hours alert])
      expect(response.body).not_to include(UrgencyHelpers::COMPLAINT)
    end

    it "dado na query → 422 com só o nome da chave; unidade que não é UPA → 422 not_an_upa; inexistente → 404" do
      board(upa, cpf: "1")
      expect_refusal(:unprocessable_entity, "invalid_request", "cpf")
      get "/urgency/observation", params: { health_unit_id: create_unit("UBS Centro").id }
      expect_refusal(:unprocessable_entity, "not_an_upa")
      get "/urgency/observation", params: { health_unit_id: SecureRandom.uuid }
      expect(response).to have_http_status(:not_found)
    end

    it "a fila traz observation.bed_label do paciente no leito e null dos demais" do
      placed = in_care_encounter!(upa)
      free = in_care_encounter!(upa)
      observed!(placed, bed: bed)
      get "/urgency/queue", params: { health_unit_id: upa.id }
      items = json_body["in_care"].index_by { |i| i["encounter_id"] }
      expect(items[placed.id]["observation"]).to eq("bed_label" => "OBS 01", "hours" => 0, "alert" => nil)
      expect(items[free.id]).to include("observation" => nil)
    end
  end
end
