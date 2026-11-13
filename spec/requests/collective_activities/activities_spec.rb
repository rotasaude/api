require "rails_helper"

# Módulo 24b (ADR 0052; contrato §2, §4, §5, §7, §11, §13; Q12–Q15, Q17, Q21,
# Q53–Q55; plano, Task 15, Desvio 11): as rotas da atividade coletiva.
#   - opções: equipes com can_register, unidades com has_cnes, profissionais com
#     has_cns e os domínios com as regras do §4 (o YAML da task 1);
#   - registro pelo CollectiveActivities::Record (201; 200 no reenvio), com as
#     recusas do 409 duplicate_suspected (candidatos, trilha) e do 422
#     duplicate_participant (confirmable);
#   - lista sem participantes, sem temas e sem trilha, `mistaken` fora por
#     padrão; detalhe com trilha (os pacientes);
#   - "registrada por engano" pelo quem registrou;
#   - Q55: atividade marcada por engano não é gerada de novo nem reenviada
#     (409 activity_changed na Produção); a ficha já enfileirada segue.
RSpec.describe "Atividade coletiva — rotas da equipe", type: :request do
  let!(:city) { home_visit_city!(collective: true) }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { field_agent!(team: team) }
  let(:nurse) { registry_nurse!(unit, team: team) }
  let(:today) { Time.zone.today }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def trail = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at).map(&:payload)

  def body(**over)
    { "client_uuid" => SecureRandom.uuid, "team_id" => team.id, "held_on" => today.iso8601, "shift" => 1, "activity_type" => 1,
      "place_text" => "Sala de reuniões", "participants_count" => 6, "meeting_topics" => [ 2 ] }.merge(over.stringify_keys)
  end

  # Tipo 5 com um participante existente.
  def group_body(patient, **over)
    body(activity_type: 5, meeting_topics: [], target_audience: [ 12 ], health_topics: [ 4 ], participants_count: 10,
         participants: [ { "patient_id" => patient.id, "altered_evaluation" => true, "measurements" => { "weight_kg" => 70.5 } } ], **over)
  end

  def record!(params = body, by: acs)
    result = CollectiveActivities::Record.call(params: params, by: by)
    raise "atividade recusada: #{result.reason} #{result.details}" if result.failure?

    result.payload[:activity]
  end

  def typed(name = "Benedita Alves Rocha")
    { "full_name" => name, "birth_date" => "1951-03-08", "sex" => "female", "no_cpf_reason" => "3" }
  end

  describe "GET /collective_activities/options" do
    it "traz equipes com can_register, unidades com has_cnes, profissionais com has_cns e domains com as regras" do
      other_team = registry_team!
      colleague = registry_nurse!(team: other_team)
      colleague.professional.update_columns(cns: "123456789012345") # dígito errado
      bare = create_unit("Escola municipal", cnes: nil)
      create_unit("UBS fechada", active: false, cnes: "7654321")
      sign_in_as(acs)
      get "/collective_activities/options"
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to contain_exactly("today", "min_date", "teams", "units", "domains")
      expect(json_body["today"]).to eq(today.iso8601)
      expect(json_body["min_date"]).to eq(HomeVisits::Rules.min_date(today).iso8601)
      member = HealthTeamMember.active.find_by!(professional: acs.professional, health_team: team)
      expect(json_body["teams"].sole.except("professionals"))
        .to eq("id" => team.id, "ine" => team.ine, "name" => team.name, "cbo" => member.cbo_code, "can_register" => true)
      units = json_body["units"].index_by { _1["id"] }
      expect(units.fetch(unit.id)).to eq("id" => unit.id, "name" => unit.name, "has_cnes" => unit.cnes.present?)
      expect(units.fetch(bare.id)).to eq("id" => bare.id, "name" => "Escola municipal", "has_cnes" => false)
      expect(json_body["units"].map { _1["name"] }).not_to include("UBS fechada")
      people = json_body["teams"].sole["professionals"].index_by { _1["id"] }
      expect(people.fetch(colleague.professional.id)).to eq(
        "id" => colleague.professional.id, "name" => colleague.professional.professional_name, "cbo" => "223505",
        "has_cns" => false, "in_team" => false
      )
      expect(people).not_to have_key(acs.professional.id) # quem registra é o cabeçalho
      expect(trail).to be_empty

      domains = json_body["domains"]
      expect(domains.keys).to contain_exactly("activity_types", "meeting_topics", "target_audience", "health_topics",
                                              "health_practices", "procedures", "rules")
      expect(domains["activity_types"].first).to eq("code" => 1, "label" => "Reunião de equipe")
      expect(domains["health_topics"].map { _1["code"] }).not_to include(18)
      expect(domains["procedures"].size).to eq(58)
      expect(domains["procedures"].first).to eq("code" => "0101050178", "label" => "ATIVIDADE COLETIVA DE ANTROPOSOFIA APLICADA À SAÚDE")
      expect(domains["rules"]).to eq(
        "list_max" => { "meeting_topics" => 7, "target_audience" => 17, "health_topics" => 16, "health_practices" => 14 },
        "by_type" => CollectiveActivities::Rules::BY_TYPE.to_h { |type, row| [ type.to_s, row ] },
        "health_topics_with_meeting_topic" => [ 6 ],
        "practices_only_in_type" => [ { "type" => 6, "practices" => [ 2, 9, 33 ] } ],
        "procedure_practices" => [ 30 ], "smoking_practices" => [ 25, 26, 27, 28 ],
        "participant_measurements" => { "weight_kg" => { "min" => 0.5, "max" => 500, "decimals" => 3 },
                                        "height_cm" => { "min" => 20, "max" => 250, "decimals" => 1 } }
      )
      expect(domains.dig("rules", "by_type", "5")).to eq("meeting_topics" => "forbidden", "target_audience" => "required",
                                                         "health_topics" => "required", "health_practices" => "optional",
                                                         "participants" => "required")
    end

    it "Q57 c: profissionais por equipe, com o CBO que o Record grava numa atividade dela (o vínculo da equipe; sem ele, o mais antigo)" do
      second = registry_team!
      HealthTeamMember.create!(professional: acs.professional, health_team: second, cbo_code: HomeVisits::Catalog::ACS_CBO,
                               started_on: today - 30)
      third = registry_team!
      colleague = registry_nurse!(team: third) # vínculo mais antigo: 223505 na terceira
      HealthTeamMember.create!(professional: colleague.professional, health_team: second, cbo_code: "225142", started_on: today - 10)
      teammate = field_agent!(team: team)
      sign_in_as(acs)
      get "/collective_activities/options"
      expect(response).to have_http_status(:ok)
      by_team = json_body["teams"].to_h { |row| [ row["id"], row["professionals"].index_by { _1["id"] } ] }
      expect(by_team.keys).to contain_exactly(team.id, second.id)
      expect(by_team.fetch(second.id).fetch(colleague.professional.id)).to include("cbo" => "225142", "in_team" => true)
      expect(by_team.fetch(team.id).fetch(colleague.professional.id)).to include("cbo" => "223505", "in_team" => false)
      expect(by_team.fetch(team.id).values.first["id"]).to eq(teammate.professional.id) # membros da equipe primeiro
      expect(by_team.values.flat_map(&:keys)).not_to include(acs.professional.id)

      [ [ second, "225142" ], [ team, "223505" ] ].each do |activity_team, cbo|
        payload = body(team_id: activity_team.id, professionals: [ { "professional_id" => colleague.professional.id } ])
        json_post "/collective_activities", payload
        expect(response).to have_http_status(:created)
        expect(json_body["professionals"].sole).to include("id" => colleague.professional.id, "cbo" => cbo)
      end
    end

    it "Q57 b: sem equipe em que leia → 200 com teams vazio (como o /home_visits/context); nada na query" do
      clerk = field_agent!(cbo: "221205", team: team)
      sign_in_as(clerk)
      get "/collective_activities/options"
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to contain_exactly("today", "min_date", "teams", "units", "domains")
      expect(json_body["teams"]).to eq([])
      expect(json_body["domains"]).to eq(JSON.parse(CollectiveActivities::Json.domains.to_json))
      sign_in_as(acs)
      get "/collective_activities/options", params: { team_id: team.id }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    end
  end

  describe "POST /collective_activities" do
    it "tipo 1 sem participantes → 201 com ficha pending; reenvio do mesmo client_uuid → 200 igual" do
      payload = body
      sign_in_as(acs)
      json_post "/collective_activities", payload
      expect(response).to have_http_status(:created)
      activity = CollectiveActivity.sole
      expect(json_body).to eq(
        "id" => activity.id, "client_uuid" => payload["client_uuid"], "team" => { "id" => team.id, "ine" => team.ine, "name" => team.name },
        "unit" => { "id" => unit.id, "name" => unit.name }, "held_on" => today.iso8601, "shift" => 1, "activity_type" => 1,
        "place" => { "text" => "Sala de reuniões" }, "participants_count" => 6, "altered_count" => 0, "meeting_topics" => [ 2 ],
        "target_audience" => [], "health_topics" => [], "health_practices" => [], "procedure_code" => nil, "professionals" => [],
        "participants" => [], "recorded_by" => { "name" => acs.professional.professional_name }, "state" => "recorded",
        "mistaken" => nil, "ficha" => { "status" => "pending", "reasons" => [] }, "can_mark_mistaken" => true
      )
      expect(trail).to eq([ { "access" => "collective_activities", "collective_activity_ids" => [ activity.id ], "patient_ids" => [],
                              "user_id" => acs.id } ])
      first = json_body

      json_post "/collective_activities", payload.merge("participants_count" => 9)
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq(first)
      expect(CollectiveActivity.count).to eq(1)
    end

    it "tipo 5 com participante e local unidade: participantes com o paciente mascarado e trilha com os pacientes" do
      patient = registry_patient!
      colleague = registry_nurse!(team: registry_team!)
      sign_in_as(acs)
      json_post "/collective_activities", group_body(patient, place_text: nil, place_health_unit_id: unit.id,
                                                              professionals: [ { "professional_id" => colleague.professional.id } ])
      expect(response).to have_http_status(:created)
      activity = CollectiveActivity.sole
      expect(json_body).to include("place" => { "health_unit" => { "id" => unit.id, "name" => unit.name } }, "altered_count" => 1,
                                   "target_audience" => [ 12 ], "health_topics" => [ 4 ],
                                   "professionals" => [ { "id" => colleague.professional.id, "name" => colleague.professional.professional_name,
                                                          "cbo" => "223505" } ])
      expect(json_body["participants"]).to eq([ {
        "patient" => { "id" => patient.id, "display_name" => patient.display_name, "has_cpf" => true, "cns_masked" => patient.cns_masked },
        "altered_evaluation" => true, "measurements" => { "weight_kg" => 70.5 }, "smoking" => nil
      } ])
      expect(response.body).not_to include(patient.cpf)
      expect(trail).to eq([ { "access" => "collective_activities", "collective_activity_ids" => [ activity.id ],
                              "patient_ids" => [ patient.id ], "user_id" => acs.id } ])
    end

    it "tipo 5 com new_patient duplicado → 409 duplicate_suspected com candidates e a trilha gravada depois da transação" do
      existing = registry_patient!
      suspect = { "full_name" => existing.full_name, "birth_date" => existing.birth_date, "sex" => "female", "no_cpf_reason" => "3" }
      payload = group_body(existing).merge("participants" => [ { "new_patient" => typed }, { "new_patient" => suspect } ])
      sign_in_as(acs)
      expect { json_post "/collective_activities", payload }.not_to change(Patient, :count)
      expect(response).to have_http_status(:conflict)
      expect(json_body.keys).to contain_exactly("error", "path", "candidates")
      expect(json_body.slice("error", "path")).to eq("error" => "duplicate_suspected", "path" => "participants[1].new_patient")
      candidate = json_body["candidates"].find { _1["patient_id"] == existing.id }
      expect(candidate.keys).to contain_exactly("patient_id", "display_name", "birth_date", "sex", "has_cpf", "has_cns")
      expect(response.body).not_to include(existing.cpf)
      expect(CollectiveActivity.count).to eq(0)
      expect(trail).to include({ "access" => "collective_activities", "patient_id" => existing.id, "user_id" => acs.id,
                                 "reason_code" => nil, "person_ref" => "patient:#{existing.id}" })

      reviewed = payload.merge("participants" => [ { "new_patient" => typed }, { "new_patient" => suspect, "duplicates_reviewed" => true } ])
      json_post "/collective_activities", reviewed
      expect(response).to have_http_status(:created)
    end

    it "a mesma pessoa duas vezes → 422 duplicate_participant com confirmable e o path participants[i]" do
      patient = registry_patient!
      sign_in_as(acs)
      json_post "/collective_activities", group_body(patient).merge("participants" => [ { "new_patient" => typed }, { "new_patient" => typed } ])
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "duplicate_participant", "path" => "participants[1]",
                                                            "confirmable" => true } ])
      json_post "/collective_activities", group_body(patient).merge("participants" => [ { "patient_id" => patient.id },
                                                                                        { "patient_id" => patient.id } ])
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "duplicate_participant", "path" => "participants[1]",
                                                            "confirmable" => false } ])
      expect(CollectiveActivity.count).to eq(0)
    end

    it "recusas pelo Desvio 11: cbo_not_allowed 403, out_of_scope 403, client_uuid_conflict 409, regra 422 com path, query 422" do
      payload = body
      sign_in_as(acs)
      json_post "/collective_activities", payload
      sign_in_as(field_agent!(team: team))
      json_post "/collective_activities", payload
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "client_uuid_conflict", "path" => "client_uuid" } ])
      sign_in_as(field_agent!(cbo: "221205", team: team))
      json_post "/collective_activities", body
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
      sign_in_as(acs)
      json_post "/collective_activities", body(team_id: registry_team!.id)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
      json_post "/collective_activities", body(health_topics: [ 18 ])
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_collective_activity", "path" => "health_topics[0]" } ])
      provisional = Patient.create!(no_cpf_reason: "unidentified", unidentified: true, unidentified_description: "homem idoso")
      json_post "/collective_activities", group_body(provisional)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "patient_unidentified", "path" => "participants[0].patient_id" } ])
      json_post "/collective_activities?team_id=#{team.id}", body
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
      expect(CollectiveActivity.count).to eq(1)
    end
  end

  describe "lista e detalhe" do
    it "lista sem participantes e sem trilha, ordem data DESC e id DESC com cursor; detalhe com trilha" do
      patient = registry_patient!
      older = record!(body(held_on: (today - 1).iso8601))
      group = record!(group_body(patient))
      plain = record!(body)
      sign_in_as(nurse)
      get "/collective_activities", params: { team_id: team.id, limit: 2 }
      expect(response).to have_http_status(:ok)
      same_day = [ group, plain ].sort_by(&:id).reverse
      expect(json_body["items"].map { _1["id"] }).to eq(same_day.map(&:id))
      item = json_body["items"].find { _1["id"] == group.id }
      expect(item.keys).to contain_exactly("id", "client_uuid", "team", "unit", "held_on", "shift", "activity_type", "place",
                                           "participants_count", "altered_count", "professionals", "recorded_by", "state",
                                           "mistaken", "ficha", "can_mark_mistaken")
      expect(item).to include("can_mark_mistaken" => false, "state" => "recorded", "ficha" => { "status" => "pending", "reasons" => [] })
      expect(json_body["next_before"]).to be_present
      get "/collective_activities", params: { team_id: team.id, limit: 2, before: json_body["next_before"] }
      expect([ json_body["items"].map { _1["id"] }, json_body["next_before"] ]).to eq([ [ older.id ], nil ])
      get "/collective_activities", params: { team_id: team.id, activity_type: [ "5" ], from: today.iso8601, to: today.iso8601 }
      expect(json_body["items"].map { _1["id"] }).to eq([ group.id ])
      expect(response.body).not_to include(patient.display_name)
      expect(trail).to be_empty

      get "/collective_activities/#{group.id}"
      expect(response).to have_http_status(:ok)
      expect(json_body["participants"].map { _1.dig("patient", "id") }).to eq([ patient.id ])
      expect(json_body).to include("health_topics" => [ 4 ], "can_mark_mistaken" => false)
      expect(trail).to eq([ { "access" => "collective_activities", "collective_activity_ids" => [ group.id ],
                              "patient_ids" => [ patient.id ], "user_id" => nurse.id } ])
    end

    it "filtros inválidos → 422 com path; cursor inválido → 422 invalid_cursor; equipe alheia → 403 out_of_scope" do
      sign_in_as(nurse)
      get "/collective_activities", params: { team_id: team.id, state: "mistaken" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "state" } ])
      get "/collective_activities", params: { team_id: team.id, activity_type: [ "9" ] }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "activity_type" } ])
      get "/collective_activities", params: { team_id: team.id, before: "x" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cursor" } ])
      get "/collective_activities", params: { team_id: team.id, full_name: "Joana" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
      get "/collective_activities", params: { team_id: registry_team!.id }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
      get "/collective_activities"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "team_id" } ])
    end

    it "atividade de outra equipe por id → 404; id que não é UUID → 404 pela rota" do
      foreign_team = registry_team!
      foreign = record!(body(team_id: foreign_team.id), by: field_agent!(team: foreign_team))
      sign_in_as(nurse)
      get "/collective_activities/#{foreign.id}"
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      json_post "/collective_activities/#{foreign.id}/mark_mistaken", expected_state: "recorded", reason: "Registrei na equipe errada"
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      get "/collective_activities/nao-e-uuid"
      expect(response).to have_http_status(:not_found)
      expect(trail).to be_empty
    end
  end

  describe "POST /collective_activities/:id/mark_mistaken" do
    it "quem registrou marca: some da lista e aparece com state[]=mistaken; o motivo só para quem registrou e o enfermeiro" do
      activity = record!
      reason = "Registrei a reunião duas vezes"
      sign_in_as(nurse)
      json_post "/collective_activities/#{activity.id}/mark_mistaken", expected_state: "recorded", reason: reason
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])

      sign_in_as(acs)
      json_post "/collective_activities/#{activity.id}/mark_mistaken", expected_state: "recorded", reason: reason, note: "x"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "note" } ])
      json_post "/collective_activities/#{activity.id}/mark_mistaken", expected_state: "recorded", reason: reason
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "mistaken", "can_mark_mistaken" => false)
      expect(json_body["mistaken"]).to include("reason" => reason, "by" => { "name" => acs.professional.professional_name })
      json_post "/collective_activities/#{activity.id}/mark_mistaken", expected_state: "recorded", reason: reason
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "activity_changed" } ])

      get "/collective_activities", params: { team_id: team.id }
      expect(json_body["items"]).to eq([])
      get "/collective_activities", params: { team_id: team.id, state: [ "mistaken" ] }
      expect(json_body["items"].map { _1["id"] }).to eq([ activity.id ])
      expect(json_body["items"].sole.dig("mistaken", "reason")).to eq(reason)

      sign_in_as(nurse)
      get "/collective_activities/#{activity.id}"
      expect(json_body.dig("mistaken", "reason")).to eq(reason)
      sign_in_as(field_agent!(team: team))
      get "/collective_activities/#{activity.id}"
      expect(json_body["mistaken"]).to include("reason" => nil)
      expect(response.body).not_to include(reason)
    end
  end

  describe "Q55: registrada por engano × Gerar de novo e Reenviar (Produção)" do
    let(:admin) { care_admin! }

    def mistaken!(activity)
      result = CollectiveActivities::MarkMistaken.call(activity, by: acs, expected_state: "recorded", reason: "Registrada em dobro")
      raise "marca recusada: #{result.reason}" if result.failure?
    end

    it "Reenviar ficha recusada de atividade por engano → 409 activity_changed; nada regerado" do
      activity = record!
      entry = LediOutboxEntry.find_by!(source_type: "CollectiveActivity", source_id: activity.id)
      entry.update_columns(status: "rejected", last_error_codes: [ { "field" => "cnes", "code" => "invalid" } ])
      mistaken!(activity)
      stepped_up!(admin)
      json_post "/production/fichas/#{entry.id}/resend"
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "activity_changed" } ])
      expect(LediOutboxEntry.where(source_id: activity.id).count).to eq(1)
    end

    it "Gerar de novo a não gerada de atividade por engano → 409 activity_changed; segue não resolvida" do
      activity = record!(body(activity_type: 5, meeting_topics: [], target_audience: [ 12 ], health_topics: [ 4 ],
                              participants: [ { "new_patient" => typed } ]))
      failure = LediGenerationFailure.find_by!(source_type: "CollectiveActivity", source_id: activity.id)
      expect(failure.reason_codes).to eq(%w[participant_without_identifier])
      mistaken!(activity)
      stepped_up!(admin)
      json_post "/production/generation_failures/#{failure.id}/retry"
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "activity_changed" } ])
      expect(failure.reload.resolved?).to be(false)
    end
  end

  it "interruptor desligado → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: CollectiveActivities::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(acs)
    [ -> { get "/collective_activities/options" }, -> { get "/collective_activities", params: { team_id: team.id } },
      -> { json_post "/collective_activities", body } ].each do |call|
      call.()
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "collective_activities" } ])
    end
  end
end
