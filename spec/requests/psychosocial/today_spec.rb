require "rails_helper"

# Módulo 31 (contrato §4): "Hoje no CAPS" — os grupos do dia da semana e as
# matrículas abertas com visita marcada na data local. Só <patient-ref> e
# <pro>; nada clínico; lista, então sem trilha.
RSpec.describe "CAPS — hoje no CAPS", type: :request do
  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:staff) { caps_staff!(caps) }
  let(:viewed) { DomainEvent.where(name: "clinical_record.viewed") }
  let(:wednesday) { Date.new(2026, 11, 4) } # quarta-feira
  let(:thursday) { wednesday + 1 }

  def group!(**over)
    PsychosocialGroup.create!({ health_unit: caps, name: "Grupo", kind: "group", weekday: 3, starts_at: "10:00", ends_at: "11:00",
                                responsible_user: staff, capacity: 10, sigtap_code: "0301080216", updated_by_user: staff }.merge(over))
  end

  def visit!(at, **over)
    enrollment!(caps, reference: staff, **over).tap { |e| e.update!(next_visit_at: at) }
  end

  def today(date, unit: caps) = get("/psychosocial/today", params: { health_unit_id: unit.id, date: date&.iso8601 }.compact)

  before { sign_in_as(staff) }

  it "o dia da semana confere: grupo de quarta aparece numa quarta e não numa quinta; inativo nunca" do
    assert_equal 3, wednesday.cwday
    manha = group!(name: "Manhã")
    tarde = group!(name: "Tarde", starts_at: "14:00", ends_at: "16:00", kind: "workshop", capacity: 8)
    group!(name: "Inativo", active: false)
    group!(name: "Sexta", weekday: 5)
    group!(name: "Outro CAPS", health_unit: caps!(modality: "caps_ad"))

    expect { today(wednesday) }.not_to(change { [ viewed.count, DomainEvent.count ] })
    expect(response).to have_http_status(:ok)
    expect(json_body["date"]).to eq("2026-11-04")
    expect(json_body["groups"].map { |g| g["id"] }).to eq([ manha.id, tarde.id ])
    expect(json_body["groups"].last).to eq("id" => tarde.id, "name" => "Tarde", "kind" => "workshop", "starts_at" => "14:00",
                                           "ends_at" => "16:00", "responsible" => Psychosocial::Json.pro(staff, "251510"),
                                           "capacity" => 8, "sigtap_code" => "0301080216", "action_id" => nil)

    today(thursday)
    expect(json_body["groups"]).to eq([])
  end

  # P56 (R3): a ação não cancelada do grupo na data local pedida (23:30 locais
  # ainda é o dia, mesmo já sendo o seguinte em UTC); cancelada não conta.
  it "action_id: a ação não cancelada do grupo no dia local; cancelada, de outro dia ou de outro grupo não contam" do
    group = group!(name: "Oficina")
    other = group!(name: "Outro")
    action = lambda do |at, of|
      PsychosocialAction.create!(health_unit: caps, sigtap_code: "0301080216", instrument: "raas_psi", performed_at: at,
                                 month: at.to_date.beginning_of_month, place: "caps", quantity: 1, professional_user: staff,
                                 cbo_code: "251510", origin: "manual", psychosocial_group: of)
    end
    action.call(Time.zone.local(2026, 11, 4, 10), group)
          .update!(cancelled_at: Time.current, cancelled_by_user: staff, cancel_reason: "Lançada por engano")
    late = action.call(Time.zone.local(2026, 11, 4, 23, 30), group)
    action.call(Time.zone.local(2026, 10, 28, 10), group)
    action.call(Time.zone.local(2026, 11, 3, 10), other)

    today(wednesday)
    by_id = json_body["groups"].index_by { |g| g["id"] }
    expect(by_id[group.id]).to include("sigtap_code" => "0301080216", "action_id" => late.id)
    expect(by_id[other.id]["action_id"]).to be_nil
    today(wednesday - 7)
    expect(json_body["groups"].find { |g| g["id"] == group.id }["action_id"]).to be_present
  end

  it "a visita das 23:30 locais entra no dia local, não no dia UTC seguinte; ordenada pela hora" do
    late = visit!(Time.zone.local(2026, 11, 4, 23, 30))
    early = visit!(Time.zone.local(2026, 11, 4, 8, 15))
    visit!(Time.zone.local(2026, 11, 5, 0, 10))   # já é quinta, local
    visit!(Time.zone.local(2026, 11, 3, 23, 59))  # terça
    expect(Time.zone.local(2026, 11, 4, 23, 30).utc.to_date).to eq(thursday) # a armadilha: em UTC já é quinta

    today(wednesday)
    expect(json_body["visits"].map { |v| v["enrollment_id"] }).to eq([ early.id, late.id ])
    expect(json_body["visits"].last).to eq("enrollment_id" => late.id, "patient" => Psychosocial::Json.patient_ref(late.patient),
                                           "next_visit_at" => "2026-11-04T23:30:00-03:00",
                                           "reference" => Psychosocial::Json.pro(staff, "251510"))
    today(thursday)
    expect(json_body["visits"].size).to eq(1)
  end

  it "só matrículas abertas do próprio CAPS" do
    visit!(Time.zone.local(2026, 11, 4, 9, 0)).update!(closed_on: Date.current, destination: "01", closed_by_user: staff)
    other = caps!(modality: "caps_ad")
    enrollment!(other, reference: caps_staff!(other)).update!(next_visit_at: Time.zone.local(2026, 11, 4, 9, 0))
    today(wednesday)
    expect(json_body["visits"]).to eq([])
  end

  it "sem date vale hoje; date fora da forma → 422 `date`" do
    visit!(Time.current.change(hour: 12))
    get "/psychosocial/today", params: { health_unit_id: caps.id }
    expect(response).to have_http_status(:ok)
    expect(json_body["date"]).to eq(Time.zone.today.iso8601)
    %w[ontem 2026-13-40 20261104].each do |bad|
      get "/psychosocial/today", params: { health_unit_id: caps.id, date: bad }
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "date" ])
    end
  end

  it "o corpo não traz nada clínico: sem cid_main, substances nem notes (nem CPF)" do
    patient = caps_patient!
    enrollment = enrollment!(caps, patient: patient, reference: staff, cid: "F200")
    enrollment.update!(next_visit_at: Time.zone.local(2026, 11, 4, 9, 0), substances: [ "01" ], cid_secondary: [ "F321" ])
    group!
    today(wednesday)
    expect(json_body["visits"].size).to eq(1)
    raw = response.body
    %w[cid_main cid_secondary substances notes].each { |key| expect(raw).not_to include(key) }
    expect(raw).not_to include("F200")
    expect(raw).not_to include("F321")
    expect(raw).not_to include(patient.cpf.to_s) if patient.respond_to?(:cpf) && patient.cpf.present?
    expect(json_body["visits"].first["patient"].keys).to contain_exactly("patient_id", "name", "cns_masked")
  end

  it "equipe de outro CAPS → 403; papel fora do CAPS → 403; sem unidade → 422; query com chave estranha → 422" do
    get "/psychosocial/today", params: { health_unit_id: caps!(modality: "caps_ad").id }
    expect([ response.status, json_body["error"] ]).to eq([ 403, "not_on_caps_team" ])
    get "/psychosocial/today"
    expect([ response.status, json_body["path"] ]).to eq([ 422, "health_unit_id" ])
    get "/psychosocial/today", params: { health_unit_id: caps.id, q: "Maria" }
    expect([ response.status, json_body["path"] ]).to eq([ 422, "q" ])

    sign_in_as(ubs_doctor!(create_unit))
    get "/psychosocial/today", params: { health_unit_id: caps.id }
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
  end
end
