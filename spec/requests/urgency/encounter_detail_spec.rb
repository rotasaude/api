require "rails_helper"

# Módulo 32a (ADR 0050; contrato §14 Q6, Q19; plano, Task 15): o detalhe do
# encontro. Com vínculo clínico na UPA (enfermagem 2235*, médico 225*), o
# detalhe inteiro; a recepção (citizen_verifier) recebe o detalhe sem o
# clínico, com a descrição do provisório; o resto → 403. Todo detalhe com
# campo clínico ou com a descrição grava a trilha (access urgency, resource
# encounter).
RSpec.describe "Urgência — detalhe do encontro", type: :request do
  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:nurse) { upa_nurse!(upa) }
  let(:doctor) { upa_doctor!(upa) }
  let(:description) { "Mulher de uns 30 anos, vestido verde, chegou de ambulância" }
  let(:encounter) do
    arrived!(upa, unidentified: description).tap do |e|
      classified!(e, color: "yellow", by: nurse, vital_signs: { spo2: 97 }, pain_scale: 6)
    end
  end

  def show(target = encounter, params = {}) = get("/urgency/encounters/#{target.id}", params: params)
  def trail = DomainEvent.where(name: "clinical_record.viewed").where("payload->>'resource' = 'encounter'")

  it "a enfermagem da UPA lê a queixa e a descrição do provisório, e isso grava a trilha" do
    sign_in_as(nurse)
    expect { show }.to change(trail, :count).by(1)
    expect(response).to have_http_status(:ok)
    detail = json_body["encounter"]
    expect(detail).to include("id" => encounter.id, "attendance_id" => encounter.attendance_id, "state" => "classified",
                              "color" => "yellow", "overdue" => false, "consultation_id" => nil, "outcome" => nil)
    expect(detail["patient"]).to include("patient_id" => encounter.attendance.patient_id, "unidentified" => true,
                                         "description" => description)
    expect(detail["classifications"].first).to include("position" => 1, "color" => "yellow",
                                                       "complaint" => UrgencyHelpers::COMPLAINT, "pain_scale" => 6,
                                                       "vital_signs" => { "spo2" => 97 },
                                                       "justification" => UrgencyHelpers::JUSTIFICATION)
    expect(trail.order(:occurred_at, :created_at).last.payload)
      .to include("patient_id" => encounter.attendance.patient_id, "user_id" => nurse.id, "access" => "urgency",
                  "resource" => "encounter", "person_ref" => "patient:#{encounter.attendance.patient_id}")
  end

  it "o médico da UPA também lê o detalhe inteiro" do
    sign_in_as(doctor)
    show
    expect(response).to have_http_status(:ok)
    expect(json_body.dig("encounter", "classifications", 0)).to include("complaint" => UrgencyHelpers::COMPLAINT)
  end

  it "a recepção lê sem o clínico, com a descrição (Q19), e grava a trilha; paciente identificado sem clínico não grava" do
    sign_in_as(upa_reception!)
    expect { show }.to change(trail, :count).by(1)
    expect(response).to have_http_status(:ok)
    detail = json_body["encounter"]
    expect(detail["patient"]).to include("description" => description)
    expect(detail["classifications"].first.keys).not_to include("complaint", "vital_signs", "pain_scale", "justification", "criterion")
    expect(response.body).not_to include(UrgencyHelpers::COMPLAINT)

    identified = arrived!(upa).tap { |e| classified!(e, color: "green", by: nurse) }
    expect { show(identified) }.not_to change(trail, :count)
    expect(response).to have_http_status(:ok)
    expect(json_body.dig("encounter", "patient").keys).not_to include("description")
  end

  it "sem vínculo clínico na UPA nem recepção → 403; id desconhecido → 404; dado na query → 422" do
    sign_in_as(doctor!(create_unit("UBS Vizinha")))
    expect { show }.not_to change(trail, :count)
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "missing_link")

    sign_in_as(staff_with("gestor-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
    show
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "missing_role")

    sign_in_as(nurse)
    get "/urgency/encounters/#{SecureRandom.uuid}"
    expect(response).to have_http_status(:not_found)
    get "/urgency/encounters/nao-e-uuid"
    expect(response).to have_http_status(:not_found)
    show(encounter, cpf: "52998224725")
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body["path"]).to eq("cpf")
  end

  it "urgency_care desligado → 403 feature_disabled" do
    encounter
    Platform::Features.set!(city: city, key: Urgency::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(nurse)
    show
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "urgency_care")
  end
  describe "observação, prescrição e administrações (módulo 32b, Q9)" do
    let!(:catalog) { import_test_catalog! }
    let(:doctor) { observation_doctor!(upa) }
    let(:nurse) { observation_nurse!(upa) }
    let(:losartana) { catalog_item(268_856) }
    let(:diazepam) { catalog_item(267_197) }
    let(:bed) { urgency_bed!(upa, label: "OBS 01") }
    let(:other_bed) { urgency_bed!(upa, label: "OBS 02") }
    let(:care) { in_care_encounter!(upa).tap { |e| urgency_consultation!(e, doctor: doctor) } }
    before { ciap2_release!; cid10_release!; sigtap_release! }
    after { Current.reset }

    def issue!(target, items)
      result = Urgency::IssuePrescription.call(encounter: target, items: items.map(&:deep_stringify_keys), by: doctor,
                                               catalog: { losartana.id => losartana, diazepam.id => diazepam })
      raise "issue! recusado: #{result.reason} #{result.details}" if result.failure?

      result.payload.fetch(:prescription)
    end

    def item(catalog_item, **over)
      { catalog_item_id: catalog_item.id, dose: "50", dose_unit: "mg", route: "oral", frequency: { kind: "interval", interval_hours: 8 } }.merge(over)
    end

    def administer!(row, at:)
      link = Urgency::Access.nursing_or_physician_link(nurse, upa.id)
      UrgencyAdministration.create!(urgency_prescription_item: row, urgency_encounter: row.urgency_prescription.urgency_encounter,
                                    status: "administered", scheduled_at: at.change(sec: 0), administered_at: at, recorded_by_user: nurse,
                                    professional_link: link, cbo_code: link.cbo_code, recorded_at: at)
    end

    it "o médico vê os três blocos: estadia atual, prescrição ativa e administrações das últimas 48 h com o controlado marcado" do
      observed!(care, bed: bed)
      v1 = issue!(care, [ item(losartana), item(diazepam, dose: "5") ])
      older = administer!(v1.items.find_by!(position: 1), at: 47.hours.ago)
      newer = administer!(v1.items.find_by!(position: 2), at: 1.hour.ago)
      administer!(v1.items.first, at: 49.hours.ago)
      sign_in_as(doctor)
      expect { show(care) }.to change(trail, :count).by(1)
      expect(response).to have_http_status(:ok)
      detail = json_body["encounter"]
      expect(detail["observation"]).to include("hours" => 0, "alert" => nil)
      current = detail.dig("observation", "current")
      expect(current).to include("bed_label" => "OBS 01", "bed_id" => bed.id, "ended_at" => nil, "ended_by" => nil)
      expect(current["started_by"]).to have_key("name")
      expect(detail.dig("observation", "stays").pluck("stay_id")).to eq([ current["stay_id"] ])
      expect(detail.dig("prescription", "id")).to eq(v1.id)
      expect(detail.dig("prescription", "items", 1)).to include("controlled" => true, "controlled_list" => "B1")
      admins = detail["administrations"]
      expect(admins.pluck("id")).to eq([ newer.id, older.id ])
      expect(admins.first).to include("prescription_item_id" => newer.urgency_prescription_item_id, "controlled" => true, "status" => "administered")
      expect(admins.first.dig("catalog_item", "catalog_item_id")).to eq(diazepam.id)
      expect(admins.last).to include("controlled" => false)
    end

    it "a administração de uma versão antiga entra nas últimas 48 h, e a prescrição é a versão ativa" do
      v1 = issue!(care, [ item(losartana) ])
      old = administer!(v1.items.first, at: 2.hours.ago)
      v2 = issue!(care, [ item(losartana, dose: "100") ])
      expect(v2.version).to eq(2)
      sign_in_as(doctor)
      show(care)
      detail = json_body["encounter"]
      expect(detail.dig("prescription", "id")).to eq(v2.id)
      expect(detail["administrations"].pluck("id")).to eq([ old.id ])
    end

    it "a recepção vê observation e NÃO tem as chaves prescription nem administrations" do
      observed!(care, bed: bed)
      v1 = issue!(care, [ item(losartana) ])
      administer!(v1.items.first, at: 1.hour.ago)
      sign_in_as(upa_reception!)
      show(care)
      expect(response).to have_http_status(:ok)
      detail = json_body["encounter"]
      expect(detail["observation"]).to include("hours" => 0)
      expect(detail["observation"]["current"]).to include("bed_label" => "OBS 01")
      expect(detail.keys).not_to include("prescription", "administrations")
    end

    it "sem estadia e sem prescrição: observation vazia, prescription nulo e administrations vazio" do
      sign_in_as(doctor)
      show(care)
      detail = json_body["encounter"]
      expect(detail["observation"]).to eq("current" => nil, "stays" => [], "hours" => 0, "alert" => nil)
      expect(detail).to include("prescription" => nil, "administrations" => [])
    end

    it "horas desde a primeira entrada e alerta; a troca de leito deixa uma estadia fechada e a atual" do
      observed!(care, bed: bed, now: 21.hours.ago)
      observed!(care, bed: other_bed, now: 1.hour.ago)
      sign_in_as(doctor)
      show(care)
      obs = json_body.dig("encounter", "observation")
      expect(obs).to include("hours" => 21, "alert" => "near_limit")
      expect(obs["stays"].pluck("bed_label")).to eq([ "OBS 01", "OBS 02" ])
      expect(obs["stays"].first).to include("end_kind" => "bed_change")
      expect(obs["current"]["bed_label"]).to eq("OBS 02")
    end

    it "o técnico 3222 continua recusado no detalhe" do
      sign_in_as(upa_nurse!(upa, cbo: "322205"))
      show(care)
      expect(response).to have_http_status(:forbidden)
    end

    it "o desfecho devolve o detalhe com a estadia fechada e a prescrição nula, com uma trilha" do
      finalized_urgency!(care, doctor: doctor)
      observed!(care, bed: bed)
      issue!(care, [ item(losartana) ])
      sign_in_as(doctor)
      expect { json_post("/urgency/encounters/#{care.id}/outcome", kind: "discharged") }.to change(trail, :count).by(1)
      expect(response).to have_http_status(:created)
      detail = json_body["encounter"]
      expect(detail["prescription"]).to be_nil
      expect(detail["observation"]["current"]).to be_nil
      expect(detail["observation"]["stays"].sole).to include("end_kind" => "outcome")
      expect(detail["observation"]["stays"].sole["ended_by"]).to be_a(Hash)
    end
  end
end
