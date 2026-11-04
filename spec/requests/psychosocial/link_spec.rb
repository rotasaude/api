require "rails_helper"

# Módulo 31 (contrato §7, P10, P27): o vínculo do paciente com o CAPS visto
# pela UBS em GET /psychosocial/patients/:id/link. Lê quem pode abrir o
# paciente pela leitura contextual do ADR 0031; os casos compartilhados são só
# os das equipes das unidades de vínculo ativo de quem lê; trilha só com caso;
# nunca CID, substância, PTS nem evolução. Relógio fixo no meio de novembro.
RSpec.describe "UBS — vínculo com o CAPS", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.zone.local(2026, 11, 18, 15, 0)) { example.run } }

  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:ubs) { HealthUnit.create!(name: "UBS Boa Vista", kind: "ubs") }
  let(:team) { HealthTeam.create!(health_unit: ubs, ine: "0000123456", kind: "70", name: "eSF Boa Vista") }
  let(:doctor) { ubs_doctor!(ubs) }
  let(:enrollment) { enrollment!(caps, started_on: Date.new(2026, 11, 3)) }
  def viewed = DomainEvent.where(name: "clinical_record.viewed")
  def link_of(patient) = get("/psychosocial/patients/#{patient.id}/link")

  it "em contexto, a UBS vê só o vínculo e o caso da própria equipe, com trilha só quando há caso" do
    caps.update!(phone: "4133334444")
    in_context!(doctor, ubs, enrollment.patient)
    sign_in_as(doctor)
    expect { link_of(enrollment.patient) }.not_to(change { viewed.count })
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("enrolled" => true, "since" => "2026-11-03", "shared_cases" => [])
    expect(json_body["caps"]).to eq("id" => caps.id, "name" => caps.name, "phone" => "4133334444")
    expect(json_body["reference"]).to eq("name" => Screenings::Json.staff_name(enrollment.reference_user))

    matrix_case!(caps, team, enrollment.patient, "Discutido manejo da insônia com a equipe")
    expect { link_of(enrollment.patient) }.to change { viewed.count }.by(1)
    expect(json_body["shared_cases"]).to eq([ { "held_on" => "2026-11-18", "caps_name" => caps.name,
                                                "shared_text" => "Discutido manejo da insônia com a equipe" } ])
    expect(viewed.last.payload).to include("patient_id" => enrollment.patient_id, "user_id" => doctor.id, "access" => "psychosocial",
                                           "resource" => "link_shared_cases")
    expect(viewed.last.payload.to_json).not_to include("insônia")
    expect(response.body).not_to include("F200")
    expect(json_body.keys).to contain_exactly("enrolled", "caps", "since", "reference", "shared_cases")
  end

  it "fora de contexto → 403 out_of_context; outra equipe não vê o caso; sem matrícula aberta → enrolled false" do
    sign_in_as(doctor)
    link_of(enrollment.patient)
    expect([ response.status, json_body["error"] ]).to eq([ 403, "out_of_context" ])

    other = HealthUnit.create!(name: "UBS Centro", kind: "ubs")
    other_doctor = ubs_doctor!(other)
    matrix_case!(caps, team, enrollment.patient, "Texto da equipe Boa Vista apenas")
    in_context!(other_doctor, other, enrollment.patient)
    sign_in_as(other_doctor)
    expect { link_of(enrollment.patient) }.not_to(change { viewed.count })
    expect(json_body["shared_cases"]).to eq([])
    expect(json_body["caps"]["phone"]).to be_nil

    lone = caps_patient!
    in_context!(other_doctor, other, lone)
    link_of(lone)
    expect(json_body).to eq("enrolled" => false)

    closed = enrollment!(caps, patient: lone, started_on: Date.new(2026, 11, 2))
    closed.update_columns(closed_on: Date.new(2026, 11, 10), destination: "01", closed_by_user_id: closed.reference_user_id)
    link_of(lone)
    expect(json_body).to eq("enrolled" => false)
  end

  it "duas matrículas abertas: o vínculo é a mais antiga" do
    other_caps = caps!(name: "CAPS AD Centro")
    older = enrollment!(other_caps, patient: enrollment.patient, started_on: Date.new(2026, 11, 1))
    in_context!(doctor, ubs, enrollment.patient)
    sign_in_as(doctor)
    link_of(enrollment.patient)
    expect(json_body["caps"]["id"]).to eq(older.health_unit_id)
    expect(json_body["since"]).to eq("2026-11-01")
  end

  it "sem health_professional (equipe do CAPS) → 403 missing_role; paciente inexistente → 404; query → 422" do
    sign_in_as(caps_staff!(caps))
    link_of(enrollment.patient)
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])

    sign_in_as(doctor)
    get "/psychosocial/patients/#{SecureRandom.uuid}/link"
    expect(response).to have_http_status(:not_found)
    get "/psychosocial/patients/#{enrollment.patient_id}/link", params: { cpf: "123" }
    expect([ response.status, json_body["path"] ]).to eq([ 422, "cpf" ])
  end

  it "interruptor desligado → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: "psychosocial_care", enabled: false, maintainer: ledi_maintainer!)
    in_context!(doctor, ubs, enrollment.patient)
    sign_in_as(doctor)
    link_of(enrollment.patient)
    expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])
  end
end
