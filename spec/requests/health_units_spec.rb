require "rails_helper"

RSpec.describe "Health units", type: :request do
  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let(:admin) { user_with("admin@cidade.gov.br", "municipal_admin") }
  let(:verifier) { user_with("atendente@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { user_with("medica@cidade.gov.br", "health_professional") }
  def body = JSON.parse(response.body)

  def user_with(email, role)
    User.create!(email_address: email, password: "senha-segura-123").tap do |u|
      Membership.create!(user: u, role: role, granted_at: Time.current)
    end
  end

  it "admin cria, edita, desativa e reativa" do
    sign_in_as(admin)

    json_post "/attendance/units", name: "UBS Centro", kind: "ubs"
    expect(response).to have_http_status(:created)
    id = body.dig("unit", "id")
    expect(body["unit"]).to include("name" => "UBS Centro", "kind" => "ubs", "active" => true)

    json_post "/attendance/units/#{id}", name: "UBS Centro Renomeada", kind: "upa"
    expect(response).to have_http_status(:ok)
    expect(body["unit"]).to include("name" => "UBS Centro Renomeada", "kind" => "upa")

    json_post "/attendance/units/#{id}/deactivate"
    expect(response).to have_http_status(:ok)
    expect(body["unit"]["active"]).to be(false)

    json_post "/attendance/units/#{id}/activate"
    expect(response).to have_http_status(:ok)
    expect(body["unit"]["active"]).to be(true)
  end

  it "nome repetido em outra caixa: 422 unit_name_taken" do
    create_unit("UBS Centro")
    sign_in_as(admin)
    json_post "/attendance/units", name: "ubs centro", kind: "ubs"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body["error"]).to eq("unit_name_taken")
  end

  it "tipo desconhecido: 422 invalid_kind" do
    sign_in_as(admin)
    json_post "/attendance/units", name: "UBS Nova", kind: "clinica"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body["error"]).to eq("invalid_kind")
  end

  # ADR 0043 (R7): a unidade de atenção primária nasce notificadora.
  it "notifying: UBS nasce true, UPA false; o corpo decide; só booleano; update só muda com a chave" do
    sign_in_as(admin)

    json_post "/attendance/units", name: "UBS Vigia", kind: "ubs"
    expect(response).to have_http_status(:created)
    expect(body["unit"]["notifying"]).to be(true)
    ubs_id = body.dig("unit", "id")

    json_post "/attendance/units", name: "UPA Vigia", kind: "upa"
    expect(body["unit"]["notifying"]).to be(false)
    upa_id = body.dig("unit", "id")

    json_post "/attendance/units", name: "UBS Fora", kind: "ubs", notifying: false
    expect(body["unit"]["notifying"]).to be(false)

    json_post "/attendance/units/#{upa_id}", name: "UPA Vigia", kind: "upa", notifying: true
    expect(response).to have_http_status(:ok)
    expect(body["unit"]["notifying"]).to be(true)

    json_post "/attendance/units/#{ubs_id}", name: "UBS Vigia Renomeada", kind: "ubs"
    expect(body["unit"]["notifying"]).to be(true)

    json_post "/attendance/units/#{ubs_id}", name: "UBS Vigia", kind: "ubs", notifying: "sim"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body["error"]).to eq("invalid_notifying")
    expect(HealthUnit.find(ubs_id).notifying).to be(true)
  end

  # Módulo 32a (contrato §1; plano, Valor fixado 4): prefixo da senha e tempos
  # de espera na TV. A UPA nasce U/true, as demais A/false; só mudam com a chave.
  it "ticket_prefix e show_wait_times: UPA nasce U/true, UBS A/false; formato conferido; update só com a chave" do
    sign_in_as(admin)

    json_post "/attendance/units", name: "UPA Senha", kind: "upa"
    expect(response).to have_http_status(:created)
    expect(body["unit"]).to include("ticket_prefix" => "U", "show_wait_times" => true)
    upa_id = body.dig("unit", "id")

    json_post "/attendance/units", name: "UBS Senha", kind: "ubs"
    expect(body["unit"]).to include("ticket_prefix" => "A", "show_wait_times" => false)

    json_post "/attendance/units", name: "UPA Leste", kind: "upa", ticket_prefix: "UL", show_wait_times: false
    expect(body["unit"]).to include("ticket_prefix" => "UL", "show_wait_times" => false)

    json_post "/attendance/units", name: "UPA Errada", kind: "upa", ticket_prefix: "u1"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body["error"]).to eq("invalid_ticket_prefix")
    expect(HealthUnit.exists?(name: "UPA Errada")).to be(false)

    json_post "/attendance/units/#{upa_id}", name: "UPA Senha", kind: "upa", ticket_prefix: "ABCD"
    expect(body["error"]).to eq("invalid_ticket_prefix")
    json_post "/attendance/units/#{upa_id}", name: "UPA Senha", kind: "upa", show_wait_times: "sim"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body["error"]).to eq("invalid_show_wait_times")

    json_post "/attendance/units/#{upa_id}", name: "UPA Senha", kind: "upa", ticket_prefix: "UPA", show_wait_times: false
    expect(response).to have_http_status(:ok)
    expect(body["unit"]).to include("ticket_prefix" => "UPA", "show_wait_times" => false)

    json_post "/attendance/units/#{upa_id}", name: "UPA Senha Centro", kind: "upa"
    expect(body["unit"]).to include("ticket_prefix" => "UPA", "show_wait_times" => false)
    get "/attendance/units"
    expect(body["units"].find { |u| u["id"] == upa_id }).to include("ticket_prefix" => "UPA", "show_wait_times" => false)
  end

  it "desativar com atendimento aberto: 409 unit_has_open_attendances; depois de encerrado, 200" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    unit = create_unit
    triage = completed_web_triage_for(citizen)
    code = Citizens::IssueCheckInCode.call(citizen: citizen, triage: triage).payload.fetch(:code)
    sign_in_as(verifier)
    json_post "/attendance/check_ins", cpf: citizen.cpf, code: code, health_unit_id: unit.id
    expect(response).to have_http_status(:created)
    attendance_id = body.dig("attendance", "id")

    sign_in_as(admin)
    json_post "/attendance/units/#{unit.id}/deactivate"
    expect(response).to have_http_status(:conflict)
    expect(body["error"]).to eq("unit_has_open_attendances")
    expect(unit.reload.active).to be(true)

    link_professional!(doctor, unit)
    sign_in_as(doctor)
    json_post "/attendance/attendances/#{attendance_id}/call", health_unit_id: unit.id
    expect(response).to have_http_status(:ok)
    json_post "/attendance/attendances/#{attendance_id}/close", outcome: "discharged"
    expect(response).to have_http_status(:ok)

    sign_in_as(admin)
    json_post "/attendance/units/#{unit.id}/deactivate"
    expect(response).to have_http_status(:ok)
    expect(body["unit"]["active"]).to be(false)
  end

  it "atendente lista só ativas e recebe 403 nas escritas e em /units/all" do
    active = create_unit("UBS Ativa")
    create_unit("UBS Inativa", active: false)
    sign_in_as(verifier)

    get "/attendance/units"
    expect(response).to have_http_status(:ok)
    expect(body["units"].map { |u| u["id"] }).to eq([ active.id ])

    get "/attendance/units/all"
    expect(response).to have_http_status(:forbidden)

    json_post "/attendance/units", name: "UBS Nova", kind: "ubs"
    expect(response).to have_http_status(:forbidden)

    json_post "/attendance/units/#{active.id}", name: "UBS Outra", kind: "ubs"
    expect(response).to have_http_status(:forbidden)

    json_post "/attendance/units/#{active.id}/deactivate"
    expect(response).to have_http_status(:forbidden)

    json_post "/attendance/units/#{active.id}/activate"
    expect(response).to have_http_status(:forbidden)
  end

  it "profissional de saúde lista só ativas e recebe 403 nas escritas e em /units/all" do
    active = create_unit("UBS Ativa")
    create_unit("UBS Inativa", active: false)
    sign_in_as(doctor)

    get "/attendance/units"
    expect(response).to have_http_status(:ok)
    expect(body["units"].map { |u| u["id"] }).to eq([ active.id ])

    get "/attendance/units/all"
    expect(response).to have_http_status(:forbidden)

    json_post "/attendance/units", name: "UBS Nova", kind: "ubs"
    expect(response).to have_http_status(:forbidden)

    json_post "/attendance/units/#{active.id}", name: "UBS Outra", kind: "ubs"
    expect(response).to have_http_status(:forbidden)

    json_post "/attendance/units/#{active.id}/deactivate"
    expect(response).to have_http_status(:forbidden)

    json_post "/attendance/units/#{active.id}/activate"
    expect(response).to have_http_status(:forbidden)
  end

  it "desativar unidade com pedido vivo: 409 unit_has_open_requests" do
    reception = staff_with("recepcao2@cidade.gov.br", "citizen_verifier")
    doctor = staff_with("medica@cidade.gov.br", "health_professional")
    unit = create_unit("UBS Sul")
    a = in_care!(waiting_attendance(Citizen.create!(cpf: "52998224725", phone: "+5541998765432"), unit: unit,
                                    by: reception), by: doctor)
    link_professional!(doctor, unit)
    Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: nil, by: doctor)
    sign_in_as(admin)
    json_post "/attendance/units/#{unit.id}/deactivate"
    expect(response).to have_http_status(:conflict)
    expect(JSON.parse(response.body)["error"]).to eq("unit_has_open_requests")
  end

  # Módulo 32b (§12 Q1): UPA com leito ativo da observação não muda de kind nem
  # é desativada (409 upa_has_beds); com os leitos desativados, passa.
  # O Urgency::SaveBed toma FOR SHARE na unidade: a conferência dos leitos da
  # edição roda sob o FOR UPDATE dela, como na desativação.
  it "a troca de kind confere os leitos ativos sob a trava da unidade" do
    upa = HealthUnit.create!(name: "UPA Trava", kind: "upa")
    UrgencyBed.create!(health_unit: upa, label: "OBS 01", updated_by_user: admin)
    sign_in_as(admin)
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    begin
      json_post "/attendance/units/#{upa.id}", name: "UPA Trava", kind: "ubs"
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    expect([ response.status, body ]).to eq([ 409, { "error" => "upa_has_beds" } ])
    unit_lock = statements.index { |sql| sql.include?('FROM "health_units"') && sql.include?("FOR UPDATE") }
    beds_check = statements.rindex { |sql| sql.include?('FROM "urgency_beds"') }
    expect(unit_lock).to be_present
    expect(beds_check).to be > unit_lock
  end

  it "UPA com leito ativo: troca de kind e desativação → 409 upa_has_beds; sem leito ativo, passa" do
    upa = HealthUnit.create!(name: "UPA Leitos", kind: "upa")
    bed = UrgencyBed.create!(health_unit: upa, label: "OBS 01", updated_by_user: admin)
    sign_in_as(admin)

    json_post "/attendance/units/#{upa.id}", name: "UPA Leitos", kind: "ubs"
    expect([ response.status, body ]).to eq([ 409, { "error" => "upa_has_beds" } ])
    json_post "/attendance/units/#{upa.id}/deactivate"
    expect([ response.status, body ]).to eq([ 409, { "error" => "upa_has_beds" } ])
    expect(upa.reload).to have_attributes(kind: "upa", active: true)

    json_post "/attendance/units/#{upa.id}", name: "UPA Renomeada", kind: "upa"
    expect(response).to have_http_status(:ok)

    bed.update!(active: false)
    json_post "/attendance/units/#{upa.id}", name: "UPA Renomeada", kind: "ubs"
    expect(response).to have_http_status(:ok)
    expect(body["unit"]).to include("kind" => "ubs")

    other = HealthUnit.create!(name: "UPA Dois", kind: "upa")
    UrgencyBed.create!(health_unit: other, label: "OBS 01", updated_by_user: admin).update!(active: false)
    json_post "/attendance/units/#{other.id}/deactivate"
    expect(response).to have_http_status(:ok)
    expect(other.reload.active).to be(false)
  end
end
