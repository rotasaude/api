require "rails_helper"
require "prism"

# Módulo 24b (ADR 0052; contrato §1, §9, §12, §13 e §16 Q22, Q23, Q25, Q31,
# Q58, Q63; plano, Task 25): o sigilo da visita domiciliar, da atividade
# coletiva e da sincronização do app de campo de ponta a ponta. Um cenário
# completo pelas rotas reais:
# - enfermeiro: atribuição de microárea e o encerramento (step-up);
# - ACS: visita realizada com motivos, medidas e observação; recusada;
#   ausente; registro rápido com CPF; retirada; as leituras da folha;
# - aparelho: cadastro (step-up), sessão, envio (visita, paciente novo com
#   CPF, visita a ele, retirada e um item que levanta exceção, Q63 a),
#   download e revogação;
# - fechamento do dia;
# - atividade tipo 6 com procedimento SIGTAP e participante, e "por engano";
# - o cidadão: GET /citizen/history e GET /citizen/care;
# - onze recusas forçadas (observação longa, CPF malformado, duplicado,
#   retirada curta, nome do aparelho longo, chave a mais no envelope, token
#   revogado, token desconhecido, chave a mais na atividade, "por engano"
#   curto e token na query não aceito).
# Depois, as provas de ausência: eventos (só ids, só os oito do §1), log
# (nem token, CPF, nome, observação, motivo, medida nem Authorization; o
# erro inesperado só com classe e client_uuid), recusas (só error, path e
# candidates, sem o valor enviado) e as visões do cidadão.
# Fora do cenário: a query de toda rota do módulo, a varredura de fonte de
# DomainEvents.publish e a de Platform.audit.
#
# Constantes do cenário num módulo próprio: dentro de um bloco do RSpec
# elas cairiam em Object e colidiriam com as de outros specs na suíte.
module HomeVisitSecrecy
  NAMES = {
    quick: "Clotilde Rápida Sigilosa",       # registro rápido pelo dashboard
    app: "Benvinda Aparelho Reservada",      # item patient do envio do app
    duplicate: "Dulcineia Candidata Sigilosa" # o candidato do duplicado (e o nome digitado)
  }.freeze
  MOTHERS = { quick: "Ernestina Mãe Rápida", app: "Rosalba Mãe Reservada", duplicate: "Iracema Mãe Duplicada" }.freeze
  TEXTS = {
    note: "Reservado V1: cachorro bravo no quintal dos fundos",
    app_note: "Reservado V2: portão azul com cadeado e campainha quebrada",
    withdrawal: "Reservado R1: lançada na casa errada da rua de cima",
    app_withdrawal: "Reservado R2: registrada no morador errado do sobrado",
    mistaken: "Reservado E1: atividade lançada na equipe errada",
    place: "Salão Reservado da Associação da Vila Sigilo"
  }.freeze
  DEVICE_NAME = "Celular da microárea 01".freeze
  LONG_NOTE = "Reservado N9: #{'observação longa ' * 30}".freeze
  SHORT_WITHDRAWAL = "Curtinho9".freeze
  SHORT_MISTAKEN = "Errinho7".freeze
  LONG_DEVICE_NAME = "Aparelho Reservado #{'y' * 50}".freeze
  BAD_CPF = "529.982.247-00".freeze
  EXTRA_NAME = "Nome Intruso Reservado".freeze
  BOGUS_TOKEN = "rsf_#{'Z' * 43}".freeze
  INTERNAL_MESSAGE = "Reservado X1: falha com nome e documento".freeze
  # Motivos (dashboard 23 e 33, app 33 e 31), medidas e o procedimento SIGTAP.
  REASONS = { done: [ 23, 33 ], app: [ 33 ], quick: [ 31 ] }.freeze
  MEASUREMENTS = {
    done: { "systolic" => 137, "diastolic" => 86, "weight_kg" => 73.125, "height_cm" => 161.5 },
    app: { "systolic" => 142, "diastolic" => 91 },
    participant: { "weight_kg" => 81.5, "height_cm" => 162.0 }
  }.freeze
  # Formas das medidas numa resposta (o número nu colidiria com ids hex).
  MEASUREMENT_FORMS = %w[137/86 142/91 73,125 73.125 161,5 161.5 81,5 mmHg systolic diastolic weight_kg height_cm].freeze
  MEASUREMENT_KEYS = %w[systolic diastolic weight_kg height_cm].freeze
  PROCEDURE = "0101050046".freeze
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  # §1: os oito eventos do contrato e as chaves exatas de cada payload.
  PAYLOAD_KEYS = {
    "home_visit.recorded" => %w[home_visit_id home_visit_day_id user_id],
    "home_visit.withdrawn" => %w[home_visit_id home_visit_day_id user_id],
    "home_visit_day.closed" => %w[home_visit_day_id closed_by],
    "collective_activity.recorded" => %w[collective_activity_id user_id],
    "collective_activity.marked_mistaken" => %w[collective_activity_id user_id],
    "field_device.registered" => %w[field_device_id user_id],
    "field_device.revoked" => %w[field_device_id user_id reason],
    "micro_area.field_assignment_changed" => %w[micro_area_id professional_id user_id ended]
  }.freeze
  CONTRACT_EVENTS = PAYLOAD_KEYS.keys.freeze
  # Os prefixos do módulo: um nome com eles fora dos oito é evento não contratado.
  MODULE_EVENT = /\A(home_visit|home_visit_day|collective_activity|field_device|field_sync)\.|\Amicro_area\.field_assignment_changed\z/
  # §13: a trilha das telas do módulo (access home_visits, collective_activities e field_sync), só ids.
  TRAIL_KEYS = %w[access user_id patient_id patient_ids home_visit_ids collective_activity_ids micro_area_id household_ids
                  field_device_id reason_code person_ref].freeze
  # A forma do candidato do duplicado (§5, Q8): HomeVisits::People.candidate.
  CANDIDATE_KEYS = %w[patient_id display_name birth_date has_cpf sex has_cns].freeze
  # As chaves do corpo que o "Parameters:" do log mostra como [FILTERED].
  LOGGED_KEYS = %w[note reasons measurements new_patient reason items participants procedure_code health_practices target_audience
                   place_text full_name cpf].freeze
  MODULE_GLOBS = %w[
    app/**/home_visits/**/*.rb app/**/collective_activities/**/*.rb app/**/field_sync/**/*.rb app/**/field_devices/**/*.rb
    app/**/*home_visit*.rb app/**/*collective_activit*.rb app/**/*field_device*.rb app/**/*field_sync*.rb
    app/models/micro_area_field_assignment.rb app/controllers/concerns/field_*.rb lib/home_visit_crew.rb
  ].freeze

  def self.formatted(cpf) = "#{cpf[0, 3]}.#{cpf[3, 3]}.#{cpf[6, 3]}-#{cpf[9, 2]}"
  def self.cpf_forms(cpf) = [ cpf, formatted(cpf) ]

  def self.dictionaries = @dictionaries ||= YAML.load_file(Rails.root.join("config/ledi/visit_activity_dictionaries.yml"))
  def self.reason_labels = REASONS.values.flatten.uniq.map { |code| dictionaries.dig("home_visit", "domains", "motivo_visita", code, "label") }

  # Rótulos de tema, prática, público e procedimento da atividade do cenário.
  def self.activity_labels
    domains = dictionaries.dig("collective_activity", "domains")
    [ domains.dig("praticas_em_saude", 30), domains.dig("publico_alvo", 12), domains.dig("outro_procedimento_coletivo", PROCEDURE) ]
  end
end

RSpec.describe "Sigilo da visita, da atividade coletiva e do app de campo (24b)", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:secrecy) { HomeVisitSecrecy }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }
  after { travel_back }

  # Cenário completo pelas rotas, com o log capturado, toda resposta guardada
  # (rota e corpo) e as recusas forçadas (corpo e valor enviado).
  def secrecy_scenario!
    s = secrecy
    city = home_visit_city!(collective: true)
    # O histórico do cidadão (módulo 20) depende do interruptor patient_timeline.
    Platform::Features.set!(city: city, key: "patient_timeline", enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    unit = care_unit!
    doctor = care_doctor!(unit)
    care_team = care_team!(unit, doctor)
    team = registry_team!(unit)
    acs = field_agent!(team: team)
    tacs = field_agent!(cbo: "322255", team: team)
    nurse = registry_nurse!(unit, team: team)
    area = registry_micro_area!(code: "01", team: team, acs: acs)
    open_area = registry_micro_area!(code: "03", team: team)
    registry_household!(micro_area: area)
    # A pessoa do cidadão: par validado com paciente, inscrita na linha de diabetes (Q25).
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    citizen = Citizen.find_by!(patient_id: patient.id)
    care_enrollment!(patient: patient, line: adopted_line!("diabetes_c4"), team: care_team, by: doctor)
    duplicate_of = Patient.create!(cpf: valid_cpf(registry_seq!), full_name: s::NAMES[:duplicate], birth_date: "1962-04-17",
                                   sex: "female", race_color: "03")
    cpfs = { quick: valid_cpf(registry_seq!), app: valid_cpf(registry_seq!), envelope: valid_cpf(registry_seq!) }

    responses = []
    refusals = []
    send_request = lambda do |verb, path, payload, headers|
      if verb == :get
        get(path, headers: headers)
      else
        post(path, params: payload.to_json, headers: { "CONTENT_TYPE" => "application/json" }.merge(headers))
      end
      responses << { verb: verb, path: request.path, status: response.status, raw: response.body.dup }
    end
    req = lambda do |verb, path, payload = {}, headers: {}|
      send_request.(verb, path, payload, headers)
      raise "#{verb} #{path} → #{response.status} #{response.body}" unless response.successful?

      response.body.empty? ? {} : JSON.parse(response.body)
    end
    refuse = lambda do |label, path, payload, status:, sent:, verb: :post, headers: {}|
      send_request.(verb, path, payload, headers)
      raise "#{label}: #{path} → #{response.status} #{response.body}" unless response.status == status

      refusals << { label: label, status: response.status, raw: response.body, json: JSON.parse(response.body), sent: Array(sent) }
    end
    occurred_at = -> { [ 1.minute.ago, Time.current.beginning_of_day ].max.change(usec: 0).iso8601 }
    visit_body = lambda do |over = {}|
      { "client_uuid" => SecureRandom.uuid, "team_id" => team.id, "occurred_at" => occurred_at.call, "micro_area_id" => area.id,
        "property_type" => "1", "subject" => "none", "outcome" => 1, "reasons" => [ 1 ], "shared" => false }.merge(over.stringify_keys)
    end
    resident = ->(over = {}) { visit_body.({ subject: "resident", patient_id: patient.id }.merge(over)) }
    activity_body = lambda do |over = {}|
      { "client_uuid" => SecureRandom.uuid, "team_id" => team.id, "held_on" => Time.zone.today.iso8601, "shift" => 1,
        "activity_type" => 6, "place_text" => s::TEXTS[:place], "participants_count" => 12, "target_audience" => [ 12 ],
        "health_practices" => [ 30 ], "procedure_code" => s::PROCEDURE,
        "participants" => [ { "patient_id" => patient.id, "altered_evaluation" => true, "measurements" => s::MEASUREMENTS[:participant] } ] }
        .merge(over.stringify_keys)
    end
    typed = lambda do |key, **over|
      { "full_name" => s::NAMES[key], "birth_date" => "1984-09-23", "sex" => "female", "mother_name" => s::MOTHERS[key] }.merge(over.stringify_keys)
    end

    ids = {}
    secrets = {}
    started_at = Time.current
    platform_events_before = PlatformEvent.count
    log = capture_log do
      # Enfermeiro: atribuição e encerramento (6A), com step-up.
      stepped_up!(nurse)
      ids[:assignment] = req.(:post, "/home_visits/assignments", { micro_area_id: open_area.id, professional_id: tacs.professional.id })["id"]
      req.(:get, "/home_visits/assignments?team_id=#{team.id}")
      req.(:post, "/home_visits/assignments/#{ids[:assignment]}/end", {})

      # ACS: realizada com motivos, medidas e observação; recusada; ausente;
      # a que será retirada; o registro rápido com CPF; as recusas forçadas.
      stepped_up!(acs)
      req.(:get, "/home_visits/context")
      done = req.(:post, "/home_visits", resident.(reasons: s::REASONS[:done], measurements: s::MEASUREMENTS[:done], note: s::TEXTS[:note]))
      ids[:done] = done.dig("visit", "id")
      ids[:day] = done.dig("day", "id")
      ids[:refused] = req.(:post, "/home_visits", resident.(outcome: 2, reasons: [])).dig("visit", "id")
      ids[:absent] = req.(:post, "/home_visits", resident.(outcome: 3, reasons: [])).dig("visit", "id")
      ids[:withdrawn] = req.(:post, "/home_visits", resident.(reasons: s::REASONS[:done])).dig("visit", "id")
      quick = req.(:post, "/home_visits", visit_body.(subject: "resident", reasons: s::REASONS[:quick],
                                                       new_patient: typed.(:quick, cpf: cpfs[:quick])))
      ids[:quick_visit] = quick.dig("visit", "id")
      ids[:quick_patient] = quick.dig("visit", "patient", "id")
      refuse.(:long_note, "/home_visits", resident.(reasons: s::REASONS[:done], note: s::LONG_NOTE), status: 422, sent: s::LONG_NOTE[0, 40])
      refuse.(:malformed_cpf, "/home_visits", visit_body.(subject: "resident", reasons: s::REASONS[:quick],
                                                          new_patient: typed.(:quick, cpf: s::BAD_CPF)),
              status: 422, sent: [ s::BAD_CPF, s::BAD_CPF.delete(".-") ])
      refuse.(:duplicate, "/home_visits", visit_body.(subject: "resident", reasons: s::REASONS[:quick],
                                                      new_patient: typed.(:duplicate, birth_date: "1962-04-17", no_cpf_reason: "3")),
              status: 409, sent: s::MOTHERS[:duplicate])
      req.(:post, "/home_visits/#{ids[:withdrawn]}/withdraw", { expected_state: "recorded", reason: s::TEXTS[:withdrawal] })
      refuse.(:short_withdrawal, "/home_visits/#{ids[:done]}/withdraw", { expected_state: "recorded", reason: s::SHORT_WITHDRAWAL },
              status: 422, sent: s::SHORT_WITHDRAWAL)
      req.(:get, "/home_visits/days/today?team_id=#{team.id}")
      ids[:detail] = req.(:get, "/home_visits/#{ids[:done]}")
      req.(:get, "/home_visits?team_id=#{team.id}")
      req.(:get, "/home_visits/count?team_id=#{team.id}")

      # Aparelho: cadastro (step-up), a lista, a sessão do app.
      registered = req.(:post, "/field_devices", { name: s::DEVICE_NAME })
      secrets[:token] = registered.fetch("token")
      secrets[:qr_payload] = registered.fetch("qr_payload")
      ids[:device] = registered.dig("device", "id")
      refuse.(:long_device_name, "/field_devices", { name: s::LONG_DEVICE_NAME }, status: 422, sent: s::LONG_DEVICE_NAME)
      req.(:get, "/field_devices")
      bearer = { "Authorization" => "Bearer #{secrets[:token]}" }
      req.(:get, "/field/v1/session", headers: bearer)

      # Envio: visita com observação e medidas, paciente novo com CPF, visita a
      # ele pelo client_uuid, retirada da primeira e um item que levanta
      # exceção (Q63 a: só ele rejected internal_error, o log só com classe e
      # client_uuid).
      ids[:internal_error] = SecureRandom.uuid
      allow(HomeVisits::Record).to receive(:call).and_wrap_original do |original, **kwargs|
        if kwargs[:params]["client_uuid"] == ids[:internal_error]
          raise ArgumentError, "#{s::INTERNAL_MESSAGE} #{s::NAMES[:app]} #{cpfs[:app]}"
        end

        original.call(**kwargs)
      end
      app_body = ->(over) { visit_body.(over).except("client_uuid").merge("occurred_at" => Time.current.change(usec: 0).iso8601) }
      ids[:app_visit] = SecureRandom.uuid
      ids[:app_patient] = SecureRandom.uuid
      items = [
        { client_uuid: ids[:app_visit], type: "home_visit",
          body: app_body.(subject: "resident", patient_id: patient.id, reasons: s::REASONS[:app], measurements: s::MEASUREMENTS[:app],
                          note: s::TEXTS[:app_note]) },
        { client_uuid: ids[:app_patient], type: "patient", body: { new_patient: typed.(:app, birth_date: "1979-02-14", cpf: cpfs[:app]) } },
        { client_uuid: SecureRandom.uuid, type: "home_visit",
          body: app_body.(subject: "resident", patient_client_uuid: ids[:app_patient], reasons: s::REASONS[:quick]) },
        { client_uuid: SecureRandom.uuid, type: "home_visit_withdrawal",
          body: { visit_client_uuid: ids[:app_visit], reason: s::TEXTS[:app_withdrawal] } },
        { client_uuid: ids[:internal_error], type: "home_visit",
          body: app_body.(subject: "resident", patient_id: patient.id, reasons: s::REASONS[:app]) }
      ]
      ids[:upload] = req.(:post, "/field/v1/uploads", { items: items }, headers: bearer).fetch("results")
      refuse.(:envelope_key, "/field/v1/uploads", { items: [ items[2] ], cpf: cpfs[:envelope] }, status: 422,
              sent: s.cpf_forms(cpfs[:envelope]), headers: bearer)
      refuse.(:token_in_query, "/field/v1/session?token=#{secrets[:token]}", nil, verb: :get, status: 401, sent: secrets[:token])
      travel(3.seconds) { ids[:changes] = req.(:get, "/field/v1/changes", headers: bearer) }

      # Revogação pelo dono; o token revogado e um desconhecido → 401.
      req.(:post, "/field_devices/#{ids[:device]}/revoke", {})
      refuse.(:revoked_token, "/field/v1/session", nil, verb: :get, status: 401, sent: secrets[:token], headers: bearer)
      refuse.(:bogus_token, "/field/v1/session", nil, verb: :get, status: 401, sent: s::BOGUS_TOKEN,
              headers: { "Authorization" => "Bearer #{s::BOGUS_TOKEN}" })

      # Fechamento do dia pelo dono.
      req.(:post, "/home_visits/days/#{ids[:day]}/close", { expected_state: "open" })

      # Atividade tipo 6 com procedimento SIGTAP e participante; "por engano".
      req.(:get, "/collective_activities/options")
      ids[:activity] = req.(:post, "/collective_activities", activity_body.()).fetch("id")
      refuse.(:extra_key, "/collective_activities", activity_body.(full_name: s::EXTRA_NAME), status: 422, sent: s::EXTRA_NAME)
      req.(:get, "/collective_activities/#{ids[:activity]}")
      req.(:get, "/collective_activities?team_id=#{team.id}")
      mistaken_path = "/collective_activities/#{ids[:activity]}/mark_mistaken"
      refuse.(:short_mistaken, mistaken_path, { expected_state: "recorded", reason: s::SHORT_MISTAKEN }, status: 422, sent: s::SHORT_MISTAKEN)
      req.(:post, mistaken_path, { expected_state: "recorded", reason: s::TEXTS[:mistaken] })

      # O cidadão, sem kinds[] (como o wpda).
      sign_in_citizen(citizen.phone)
      ids[:history] = req.(:get, "/citizen/history?citizen_id=#{citizen.id}")
      ids[:care] = req.(:get, "/citizen/care?citizen_id=#{citizen.id}")
    end

    { ids: ids, secrets: secrets, cpfs: cpfs, log: log, responses: responses, refusals: refusals, started_at: started_at,
      platform_events: PlatformEvent.count - platform_events_before, patient: patient, duplicate_of: duplicate_of, acs: acs,
      team: team, area: area }
  end

  describe "cenário" do
    let!(:scenario) { secrecy_scenario! }
    let(:ids) { scenario[:ids] }
    let(:patient) { scenario[:patient] }
    let(:token_forms) do
      token = scenario[:secrets][:token]
      [ token, token.delete_prefix("rsf_"), scenario[:secrets][:qr_payload], FieldDevice.digest(token) ]
    end
    let(:people) do
      cpfs = scenario[:cpfs].values + [ patient.cpf, scenario[:duplicate_of].cpf ]
      secrecy::NAMES.values + secrecy::MOTHERS.values + [ patient.full_name ] + cpfs.flat_map { |cpf| secrecy.cpf_forms(cpf) } +
        [ patient.cns ].compact_blank
    end
    let(:texts) do
      secrecy::TEXTS.values + [ secrecy::LONG_NOTE[0, 40], secrecy::SHORT_WITHDRAWAL, secrecy::SHORT_MISTAKEN, secrecy::EXTRA_NAME,
                                secrecy::INTERNAL_MESSAGE ]
    end
    let(:clinical) { secrecy.reason_labels + secrecy.activity_labels + [ secrecy::PROCEDURE ] }
    let(:events) { DomainEvent.where(occurred_at: scenario[:started_at]..).order(:occurred_at).to_a }

    it "percorreu o cenário inteiro (controle positivo)" do
      visits = HomeVisit.where(id: ids.values_at(:done, :refused, :absent, :withdrawn, :quick_visit)).index_by(&:id)
      expect(visits.size).to eq(5)
      expect(visits[ids[:done]]).to have_attributes(outcome: 1, reasons: secrecy::REASONS[:done], note: secrecy::TEXTS[:note],
                                                    measurements: secrecy::MEASUREMENTS[:done], withdrawn_at: nil)
      expect(visits.values_at(ids[:refused], ids[:absent]).map(&:outcome)).to eq([ 2, 3 ])
      expect(visits[ids[:withdrawn]].withdrawal_reason).to eq(secrecy::TEXTS[:withdrawal])
      expect(Patient.find(ids[:quick_patient])).to have_attributes(full_name: secrecy::NAMES[:quick], cpf: scenario[:cpfs][:quick])
      expect(ids[:detail]).to include("note" => secrecy::TEXTS[:note], "measurements" => secrecy::MEASUREMENTS[:done])

      results = ids[:upload]
      expect(results.map { |r| r["status"] }).to eq(%w[accepted accepted accepted accepted rejected])
      expect(results.last).to eq("client_uuid" => ids[:internal_error], "status" => "rejected", "type" => "home_visit", "error" => "internal_error")
      app_visit = HomeVisit.find_by!(client_uuid: ids[:app_visit])
      expect(app_visit).to have_attributes(origin: "field_app", note: secrecy::TEXTS[:app_note], withdrawal_reason: secrecy::TEXTS[:app_withdrawal])
      expect(Patient.find(results[1]["id"])).to have_attributes(full_name: secrecy::NAMES[:app], cpf: scenario[:cpfs][:app])
      expect(HomeVisit.where(client_uuid: ids[:internal_error])).to be_empty
      expect(ids[:changes]).to include("reset" => false)
      expect(ids[:changes]["items"]).not_to be_empty

      expect(HomeVisitDay.find(ids[:day])).to have_attributes(state: "closed", closed_by: "user")
      expect(FieldDevice.find(ids[:device])).to have_attributes(revoked_reason: "user")
      expect(MicroAreaFieldAssignment.find(ids[:assignment]).ended_at).to be_present
      activity = CollectiveActivity.find(ids[:activity])
      expect(activity).to have_attributes(activity_type: 6, procedure_code: secrecy::PROCEDURE, health_practices: [ 30 ],
                                          mistaken_reason: secrecy::TEXTS[:mistaken])
      expect(activity.participants.sole.patient_id).to eq(patient.id)
      expect(scenario[:refusals].map { |r| r[:label] })
        .to eq(%i[long_note malformed_cpf duplicate short_withdrawal long_device_name envelope_key token_in_query revoked_token
                  bogus_token extra_key short_mistaken])
    end

    # §1 e §13: os eventos do módulo são só os oito do contrato, e cada
    # payload só leva as suas chaves (ids, closed_by, reason, ended).
    it "os eventos do módulo publicados ⊂ os oito do §1, cada payload só com as chaves do contrato e sem pessoa nem texto" do
      module_events = events.select { |e| e.name.match?(secrecy::MODULE_EVENT) }
      expect(module_events.map(&:name).uniq - secrecy::CONTRACT_EVENTS).to be_empty
      expect(module_events.map(&:name).tally).to eq(
        "micro_area.field_assignment_changed" => 2, "home_visit.recorded" => 7, "home_visit.withdrawn" => 2,
        "field_device.registered" => 1, "field_device.revoked" => 1, "home_visit_day.closed" => 1,
        "collective_activity.recorded" => 1, "collective_activity.marked_mistaken" => 1
      )

      module_events.each do |event|
        expect(event.payload.keys).to match_array(secrecy::PAYLOAD_KEYS.fetch(event.name)), "#{event.name} publica #{event.payload.keys}"
        event.payload.each do |key, value|
          case key
          when "closed_by" then expect(value).to be_in(HomeVisits::Catalog::CLOSED_BY)
          when "reason" then expect(value).to be_in(FieldSync::Catalog::REVOKED_REASONS)
          when "ended" then expect(value).to be_in([ true, false ])
          else expect(value.to_s).to match(secrecy::UUID), "#{event.name}.#{key}"
          end
        end
      end
      expect(module_events.select { |e| e.name == "micro_area.field_assignment_changed" }.map { |e| e.payload["ended"] }).to eq([ false, true ])
      expect(module_events.find { |e| e.name == "field_device.revoked" }.payload["reason"]).to eq("user")

      # A trilha das telas do módulo: só ids e o access.
      trail = events.select { |e| e.name == "clinical_record.viewed" && e.payload["access"].in?(%w[home_visits collective_activities field_sync]) }
      expect(trail.map { |e| e.payload["access"] }.uniq).to contain_exactly("home_visits", "collective_activities", "field_sync")
      trail.each { |event| expect(event.payload.keys - secrecy::TRAIL_KEYS).to be_empty, "trilha #{event.payload.keys}" }

      payloads = (module_events + trail).map { |e| [ e.name, e.payload ] }.to_json
      (people + texts + clinical + token_forms + secrecy::MEASUREMENT_KEYS + %w[note measurements reasons])
        .each { |secret| expect(payloads).not_to include(secret), "evento contém #{secret.inspect}" }
    end

    it "o log do cenário não tem token, CPF, nome, observação, motivo, medida nem o Authorization; o erro inesperado só com classe e client_uuid" do
      log = scenario[:log]
      # Controle: a captura viu as requisições e o filtro agiu.
      expect(log).to include("/home_visits", "/collective_activities", "/field_devices", "/field/v1/uploads", "/field/v1/changes",
                             "/citizen/history", "[FILTERED]")
      (people + texts + clinical + token_forms + [ "Bearer", "Authorization", "HTTP_AUTHORIZATION" ])
        .each { |secret| expect(log).not_to include(secret), "log contém #{secret.inspect}" }
      # As medidas: o nome da coluna aparece no SQL de outros módulos (consultations.systolic); o que
      # não pode aparecer é a chave com valor, como parâmetro (=>) ou JSON (:).
      expect(log).not_to match(/"(#{secrecy::MEASUREMENT_KEYS.join('|')})"\s*(=>|:)/)

      logged = log.scan(/"(#{secrecy::LOGGED_KEYS.join('|')})"\s*=>\s*([^,}]+)/)
      expect(logged.map(&:first).uniq).to include("note", "reasons", "measurements", "new_patient", "reason", "items", "participants",
                                                   "procedure_code", "health_practices", "target_audience", "place_text", "full_name", "cpf")
      expect(logged.map(&:last)).to all(include("[FILTERED]"))

      # Q63 a: uma linha só, com a classe e o client_uuid.
      expect(log.lines.grep(/internal_error/).map(&:strip))
        .to eq([ "[field_sync.upload] internal_error class=ArgumentError client_uuid=#{ids[:internal_error]}" ])
    end

    it "toda recusa 4xx forçada traz só error, path e candidates, sem o valor enviado" do
      expected = {
        long_note: %w[invalid_home_visit note], malformed_cpf: %w[invalid_cpf new_patient.cpf], duplicate: %w[duplicate_suspected new_patient],
        short_withdrawal: %w[invalid_request reason], long_device_name: %w[invalid_request name], envelope_key: %w[invalid_request cpf],
        token_in_query: [ "invalid_token", nil ], revoked_token: [ "device_revoked", nil ], bogus_token: [ "invalid_token", nil ],
        extra_key: %w[invalid_collective_activity full_name], short_mistaken: %w[invalid_request reason]
      }
      scenario[:refusals].each do |refusal|
        json = refusal[:json]
        expect(refusal[:status]).to be_between(400, 499)
        expect(json.keys - %w[error path candidates]).to be_empty, "#{refusal[:label]}: #{json.keys}"
        expect(json.values_at("error", "path")).to eq(expected.fetch(refusal[:label])), "#{refusal[:label]}: #{json}"
        refusal[:sent].each { |sent| expect(refusal[:raw]).not_to include(sent), "#{refusal[:label]} ecoa o valor enviado" }

        # O duplicado mostra o candidato (o nome e o nascimento dele são os digitados, §5): só a forma do candidato.
        allowed = refusal[:label] == :duplicate ? [ secrecy::NAMES[:duplicate] ] : []
        (people + texts + token_forms - allowed).each do |secret|
          expect(refusal[:raw]).not_to include(secret), "#{refusal[:label]} contém #{secret.inspect}"
        end
      end
      candidates = scenario[:refusals].find { |r| r[:label] == :duplicate }[:json].fetch("candidates")
      expect(candidates.map { |c| c["patient_id"] }).to eq([ scenario[:duplicate_of].id ])
      candidates.each { |candidate| expect(candidate.keys - secrecy::CANDIDATE_KEYS).to be_empty }
      expect(scenario[:refusals].reject { |r| r[:label] == :duplicate }.map { |r| r[:json] }).to all(satisfy { |j| !j.key?("candidates") })
    end

    # §12, Q22, Q23, Q25: o cidadão vê só a realizada e não retirada, na forma
    # fixa; nunca a recusa, a ausência, a retirada, o motivo, a medida, a
    # observação nem o nome do profissional; a atividade coletiva nunca.
    it "GET /citizen/history e GET /citizen/care não trazem recusa, ausência, retirada, motivo, medida, observação nem profissional" do
      history = ids[:history]
      visits = history.fetch("entries").select { |entry| entry["kind"] == "home_visit" }
      expect(visits).to eq([ { "id" => "home_visit:#{ids[:done]}", "kind" => "home_visit",
                               "occurred_at" => "#{Time.zone.today.iso8601}T12:00:00-03:00", "unit" => nil, "professional_name" => nil,
                               "title" => "Visita do agente de saúde", "summary" => nil, "status" => nil, "document" => nil } ])
      expect(history.fetch("entries").map { |entry| entry["kind"] }).not_to include("collective_activity")

      care_items = ids[:care].fetch("lines").flat_map { |line| line["items"] }
      expect(care_items.find { |item| item["label"] == "Visitas do agente de saúde" }).to include("by_team" => true) # controle
      care_items.each { |item| expect(item.keys).to eq(%w[label status due_on by_team]) }

      hidden_ids = ids.values_at(:refused, :absent, :withdrawn, :activity) + [ HomeVisit.find_by!(client_uuid: ids[:app_visit]).id ]
      professional = scenario[:acs].professional.professional_name
      outcome_labels = secrecy.dictionaries.dig("home_visit", "domains", "desfecho").values
      citizen_views = scenario[:responses].select { |r| r[:path].in?(%w[/citizen/history /citizen/care]) }
      expect(citizen_views.size).to eq(2)
      citizen_views.each do |view|
        (hidden_ids + texts + clinical + secrecy::MEASUREMENT_FORMS + outcome_labels +
         [ professional, "withdrawn", "refused", "absent", "Retirada", "note", "reasons", "measurements" ]).each do |secret|
          expect(view[:raw]).not_to include(secret), "#{view[:path]} contém #{secret.inspect}"
        end
      end
    end

    it "nenhum Platform.audit durante o cenário" do
      expect(scenario[:platform_events]).to eq(0)
    end
  end
end

# §13 (nunca em URL): toda rota de /home_visits, /collective_activities e
# /field/v1 recusa pessoa e texto na query (422 invalid_request), sem ecoar o
# valor — inclusive as que só leem, as que gravam e as do app de campo.
RSpec.describe "Sigilo da visita (24b) — query de toda rota", type: :request do
  let!(:city) { home_visit_city!(collective: true) }
  let(:team) { registry_team! }
  let(:acs) { field_agent!(team: team) }
  let!(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }

  def module_routes
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      [ route.verb, path ] if path.match?(%r{\A/(home_visits|collective_activities|field/v1)(/|\z)})
    end.uniq
  end

  it "o módulo tem as 27 rotas do plano (17 da visita, 7 da atividade e 3 do app)" do
    routes = module_routes
    expect(routes.count { |_, path| path.start_with?("/home_visits") }).to eq(17)
    expect(routes.count { |_, path| path.start_with?("/collective_activities") }).to eq(7)
    expect(routes.count { |_, path| path.start_with?("/field/v1/") }).to eq(3)
  end

  it "toda rota recusa cpf e note na query (422 invalid_request, sem o valor)" do
    # Corrigido na rodada 1 da Task 25: assignments e /field/v1/* ganharam a guarda.
    values = { "cpf" => "52998224725", "note" => "Texto reservado na query da rota" }
    stepped_up!(acs)
    token = FieldDevices::Register.call(user: acs, name: "Celular").payload.fetch(:token)
    failures = []
    module_routes.each do |verb, route|
      path = route.gsub(/:\w+/) { SecureRandom.uuid }
      values.each do |key, value|
        url = "#{path}?#{key}=#{CGI.escape(value)}"
        headers = { "CONTENT_TYPE" => "application/json" }
        headers["Authorization"] = "Bearer #{token}" if path.start_with?("/field/v1/")
        verb == "GET" ? get(url, headers: headers) : post(url, params: "{}", headers: headers)
        json = JSON.parse(response.body) rescue {}
        refused = response.status == 422 && json["error"] == "invalid_request" && json["path"].in?([ nil, key ])
        failures << "#{verb} #{route}?#{key} → #{response.status} #{response.body[0, 120]}" unless refused
        failures << "#{verb} #{route}?#{key} ecoa o valor" if response.body.include?(value)
      end
    end
    expect(failures).to be_empty, failures.join("\n")
  end
end

# §1 e §13: a varredura de fonte (Prism) — todo DomainEvents.publish em app/
# e lib/ com nome do módulo usa um dos oito do contrato, com nome literal (ou
# constante do arquivo) e só as chaves do contrato; nos arquivos do módulo,
# só os oito e a trilha clinical_record.viewed (só ids).
RSpec.describe "Sigilo da visita (24b) — DomainEvents.publish na fonte" do
  # Nome do evento: literal, ou a constante escrita no próprio arquivo
  # (EVENT = "…".freeze); nil quando dinâmico.
  def event_name(call, constants)
    arg = call.arguments&.arguments&.first
    case arg
    when Prism::StringNode then arg.unescaped
    when Prism::ConstantReadNode then constants[arg.name]
    end
  end

  def publish_calls
    Dir[Rails.root.join("{app,lib}/**/*.rb").to_s].flat_map do |file|
      constants = {}
      found = []
      walk = lambda do |node|
        if node.is_a?(Prism::ConstantWriteNode)
          value = node.value
          value = value.receiver if value.is_a?(Prism::CallNode) && value.name == :freeze
          constants[node.name] = value.unescaped if value.is_a?(Prism::StringNode)
        end
        if node.is_a?(Prism::CallNode) && node.name == :publish && node.receiver.respond_to?(:full_name) &&
           node.receiver.full_name.delete_prefix("::") == "DomainEvents"
          found << node
        end
        node.compact_child_nodes.each { |child| walk.call(child) }
      end
      walk.call(Prism.parse_file(file).value)
      found.map { |call| [ file, call, event_name(call, constants) ] }
    end
  end

  def keys_of(call)
    call.arguments.arguments.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode)
        .map { |assoc| assoc.key.respond_to?(:unescaped) ? assoc.key.unescaped : assoc.key.slice }
  end

  def module_file?(file)
    @module_files ||= HomeVisitSecrecy::MODULE_GLOBS.flat_map { |glob| Dir[Rails.root.join(glob).to_s] }.to_set
    @module_files.include?(file)
  end

  it "só os oito nomes do §1 (os dois catálogos), com as chaves exatas do contrato" do
    expect(HomeVisits::Catalog::DOMAIN_EVENTS + CollectiveActivities::Catalog::DOMAIN_EVENTS).to match_array(HomeVisitSecrecy::CONTRACT_EVENTS)
    calls = publish_calls
    expect(calls.size).to be > 300 # controle: a varredura achou as chamadas do app

    contracted = calls.select { |_, _, name| name&.match?(HomeVisitSecrecy::MODULE_EVENT) }
    contracted.each do |file, call, name|
      where = "#{file.delete_prefix("#{Rails.root}/")}:#{call.location.start_line}"
      expect(HomeVisitSecrecy::CONTRACT_EVENTS).to include(name), "#{where}: #{name} fora do contrato"
      expect(keys_of(call)).to match_array(HomeVisitSecrecy::PAYLOAD_KEYS.fetch(name)), "#{where}: chaves #{keys_of(call)}"
    end
    expect(contracted.map(&:last).uniq).to match_array(HomeVisitSecrecy::CONTRACT_EVENTS)
    expect(contracted.size).to eq(9) # um call site por evento; micro_area.field_assignment_changed em dois (atribuir e encerrar)
  end

  it "nos arquivos do módulo, todo publish tem nome resolvido e é um dos oito ou a trilha (só ids)" do
    module_calls = publish_calls.select { |file, _, _| module_file?(file) }
    expect(module_calls.size).to eq(16) # os 9 dos oito eventos e os 7 da trilha
    module_calls.each do |file, call, name|
      where = "#{file.delete_prefix("#{Rails.root}/")}:#{call.location.start_line}"
      expect(name).to be_present, "#{where}: o nome do evento deve ser literal ou constante do arquivo"
      expect(HomeVisitSecrecy::CONTRACT_EVENTS + [ "clinical_record.viewed" ]).to include(name), "#{where}: #{name}"
      next unless name == "clinical_record.viewed"

      expect(keys_of(call) - HomeVisitSecrecy::TRAIL_KEYS).to be_empty, "#{where}: trilha com #{keys_of(call)}"
    end
  end
end

# §1, §13 e C17 (nenhum nome novo de Platform.audit): o módulo não audita na
# plataforma. Platform.audit( é multilinha: procura-se o nó da chamada (Prism)
# e o nome da chamada, que não quebra linha, em todo arquivo do módulo.
RSpec.describe "Sigilo da visita (24b) — sem Platform.audit novo" do
  def audit_calls(file)
    found = []
    walk = lambda do |node|
      if node.is_a?(Prism::CallNode) && node.name == :audit && node.receiver.respond_to?(:full_name) &&
         node.receiver.full_name.delete_prefix("::") == "Platform"
        found << node
      end
      node.compact_child_nodes.each { |child| walk.call(child) }
    end
    walk.call(Prism.parse_file(file).value)
    found
  end

  it "nenhum arquivo do módulo chama Platform.audit e R18 segue sem nome do módulo" do
    files = HomeVisitSecrecy::MODULE_GLOBS.flat_map { |glob| Dir[Rails.root.join(glob).to_s] }.uniq
    expect(files.size).to be >= 70
    %w[app/commands/home_visits/record.rb app/commands/collective_activities/mark_mistaken.rb app/commands/field_devices/revoke.rb
       app/services/field_sync/upload.rb app/controllers/concerns/field_authentication.rb app/controllers/field_devices_controller.rb
       app/jobs/home_visits/close_days_job.rb app/models/micro_area_field_assignment.rb
       app/services/timeline/sources/home_visit_source.rb app/services/ledi/home_visit_day_ficha.rb lib/home_visit_crew.rb].each do |path|
      expect(files).to include(Rails.root.join(path).to_s), "#{path} fora das globs"
    end
    expect(files.flat_map { |file| audit_calls(file) }).to be_empty
    expect(files.select { |file| File.read(file).match?(/Platform\s*\.\s*audit\b/) }).to be_empty

    app_audits = Dir[Rails.root.join("{app,lib}/**/*.{rb,rake}").to_s].sum { |file| audit_calls(file).size }
    expect(app_audits).to be > 0 # controle: a varredura acha os Platform.audit da plataforma

    guard = File.read(Rails.root.join("spec/events/platform_event_payload_guard_spec.rb"))
    r18 = guard[/R18_PLATFORM_EVENT_NAMES = %w\[(.*?)\]\.freeze/m, 1].to_s.split
    expect(r18).to include("city.feature_changed", "care_line.template_changed") # os dois que o 24b usa (§1)
    expect(r18.grep(/home_visit|collective_activit|field_device|field_sync|micro_area/)).to be_empty
    expect(Platform::Features::KEYS).to include(HomeVisits::Gate::KEY, CollectiveActivities::Gate::KEY)
  end
end
