require "rails_helper"

# Módulo 32a (ADR 0050; contrato §12, §13 e §14 Q8, Q13, Q19, Q25, Q27; plano,
# Task 18): o sigilo da urgência de ponta a ponta. Um cenário completo pelas
# rotas reais (TV pareada; busca pelo CPF e chegada; chegada de dois
# provisórios; chamada para a classificação com local; classificação com
# queixa e dor, e a reclassificação; chamada do médico com local e "chamar de
# novo"; consulta de urgência com CID; alta com orientação de retorno;
# identificação com fusão; óbito do identificado; evasão do provisório;
# chegada registrada por engano; TV revogada), com quatro recusas forçadas
# (CPF malformado, descrição curta, justificativa curta e destino ausente),
# e depois as provas de ausência: eventos (só ids), log, recusas, URLs,
# painel da TV, histórico do cidadão (o wpda) e página do PEC externo (Q27:
# forma profissional, com cor e CID). Fora do cenário: a query das leituras
# do módulo e a varredura de fonte de Platform.audit.
#
# Constantes do cenário num módulo próprio: dentro de um bloco do RSpec
# elas cairiam em Object e colidiriam com as de outros specs na suíte.
module UrgencySecrecy
  NAME = "Benedita Aparecida Fontoura".freeze
  DOCTOR_CPF = "52998224725".freeze
  BAD_CPF = "52998224700".freeze
  SHORT_DESCRIPTION = "Idoso só".freeze
  SHORT_JUSTIFICATION = "Sem dor".freeze
  TEXTS = {
    complaint_a: "Dor no peito irradiando para o braço esquerdo",
    complaint_b: "Falta de ar súbita depois de queda na escada",
    criterion_a: "Dor intensa (8 a 10)",
    criterion_b: "SpO2 abaixo de 90%",
    description_b: "Homem, cerca de 40 anos, tatuagem de âncora no braço",
    description_c: "Mulher, cerca de 25 anos, encontrada no terminal rodoviário",
    return_reason: "Reavaliar a pressão arterial depois do ajuste da medicação",
    error_reason: "Chegada lançada no paciente errado pela recepção",
    cid_name: "Hipertensão essencial"
  }.freeze
  # O CID curto ("I10") cabe num base64 de texto cifrado (SQL do log): só
  # conta isolado, fora de palavra, de base64 e de padding.
  CID = /(?<![A-Za-z0-9+\/])I10(?![A-Za-z0-9+\/=])/
  COLOR_WORDS = /\b(red|orange|yellow|green|blue|vermelh[oa]|laranja|amarel[oa]|verde|azul)\b/i
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  MODULE_GLOBS = %w[
    app/**/urgency/**/*.rb app/**/waiting_room/**/*.rb app/**/*urgency*.rb app/**/*waiting_room*.rb
    app/**/*call_location*.rb app/models/attendance_call.rb app/commands/attendances/recall.rb
    app/services/attendances/call_record.rb app/services/attendances/ticket.rb
    app/services/protocols/name_kind_conflict.rb app/controllers/concerns/month_param.rb lib/urgency_crew.rb
  ].freeze
end

RSpec.describe "Sigilo da urgência (32a)", type: :request do
  def anonymous!
    reset!
    host! test_city_host
  end

  # Cenário completo pelas rotas, com o log capturado, as URLs anotadas, as
  # recusas forçadas guardadas (corpo e valor enviado) e as leituras da TV.
  def secrecy_scenario!
    city = urgency_city!(waiting_room: true)
    timeline_city!(documents: true, pec: true)
    pec_settings!
    ciap2_release!; cid10_release!; sigtap_release!
    urgency_protocol!
    upa = upa!(name: "UPA Boqueirão", cnes: "7654321")
    nurse = upa_nurse!(upa)
    doctor = upa_doctor!(upa).tap { |u| u.professional.update!(cpf: UrgencySecrecy::DOCTOR_CPF) }
    reception = upa_reception!
    admin = urgency_admin!
    room = call_location!(upa, name: "Consultório 1")
    triage_room = call_location!(upa, name: "Sala de classificação")
    patient = urgency_patient!(urgency_seq!).tap { |p| p.update!(full_name: UrgencySecrecy::NAME) }
    phone = "+5541988887018"
    Citizen.create!(cpf: patient.cpf, phone: phone, verification_level: "verified", patient_id: patient.id)

    paths = []
    refusals = []
    boards = []
    started_at = Time.current
    send_request = lambda do |verb, path, body, headers|
      case verb
      when :get then get(path, headers: headers)
      when :patch then json_patch(path, body)
      else post(path, params: body.to_json, headers: { "CONTENT_TYPE" => "application/json" }.merge(headers))
      end
      paths << request.fullpath
    end
    req = lambda do |verb, path, body = {}, headers: {}|
      send_request.(verb, path, body, headers)
      raise "#{verb} #{path} → #{response.status} #{response.body}" unless response.successful?

      response.body.empty? ? {} : JSON.parse(response.body)
    end
    refuse = lambda do |label, path, body, status:, sent:|
      send_request.(:post, path, body, {})
      raise "#{label}: #{path} → #{response.status} #{response.body}" unless response.status == status

      refusals << { label: label, status: response.status, raw: response.body, json: JSON.parse(response.body), sent: sent }
    end
    board = -> { anonymous!; boards << req.(:get, "/waiting_room/board", nil, headers: { "X-Display-Token" => @display_token }) }

    ids = {}
    log = capture_log do
      # TV: cadastro, código e pareamento (o token só na resposta do pareamento).
      stepped_up!(admin)
      ids[:display] = req.(:post, "/waiting_room/displays", { health_unit_id: upa.id, name: "TV da recepção" })["id"]
      ids[:pairing_code] = req.(:post, "/waiting_room/displays/#{ids[:display]}/pairing_code", {})["code"]
      anonymous!
      @display_token = req.(:post, "/waiting_room/pair", { code: ids[:pairing_code] })["display_token"]

      # Recepção: busca pelo CPF (e a malformada), chegada e dois provisórios.
      sign_in_as(reception)
      refuse.(:malformed_cpf, "/urgency/person_lookup", { cpf: UrgencySecrecy::BAD_CPF }, status: 422, sent: UrgencySecrecy::BAD_CPF)
      found = req.(:post, "/urgency/person_lookup", { cpf: patient.cpf })
      a = req.(:post, "/urgency/arrivals", { health_unit_id: upa.id, patient_id: found.dig("patient", "patient_id") })
      refuse.(:short_description, "/urgency/arrivals", { health_unit_id: upa.id, unidentified: { description: UrgencySecrecy::SHORT_DESCRIPTION } },
              status: 422, sent: UrgencySecrecy::SHORT_DESCRIPTION)
      b = req.(:post, "/urgency/arrivals", { health_unit_id: upa.id, unidentified: { description: UrgencySecrecy::TEXTS[:description_b] } })
      c = req.(:post, "/urgency/arrivals", { health_unit_id: upa.id, unidentified: { description: UrgencySecrecy::TEXTS[:description_c] } })
      ids.merge!(a: a["encounter_id"], a_attendance: a["attendance_id"], b: b["encounter_id"], b_attendance: b["attendance_id"],
                 c: c["encounter_id"], provisional_b: b.dig("patient", "patient_id"), provisional_c: c.dig("patient", "patient_id"))
      req.(:get, "/urgency/queue?health_unit_id=#{upa.id}")

      # Enfermagem: chamada para a classificação com local, classificação com
      # queixa e dor (a recusa da justificativa curta antes), reclassificação.
      sign_in_as(nurse)
      req.(:post, "/urgency/encounters/#{ids[:a]}/call_for_classification", { call_location_id: triage_room.id })
      classify_a = { complaint: UrgencySecrecy::TEXTS[:complaint_a], vital_signs: {}, pain_scale: 9 }
      refuse.(:short_justification, "/urgency/encounters/#{ids[:a]}/classifications",
              classify_a.merge(color: "yellow", justification: UrgencySecrecy::SHORT_JUSTIFICATION), status: 422, sent: UrgencySecrecy::SHORT_JUSTIFICATION)
      req.(:post, "/urgency/encounters/#{ids[:a]}/classifications", classify_a.merge(color: "orange"))
      req.(:post, "/urgency/encounters/#{ids[:a]}/classifications", classify_a.merge(color: "orange"))
      req.(:post, "/urgency/encounters/#{ids[:b]}/classifications",
           { complaint: UrgencySecrecy::TEXTS[:complaint_b], vital_signs: { spo2: 85 }, pain_scale: 2, color: "red" })
      req.(:get, "/urgency/encounters/#{ids[:a]}")
      board.()

      # Médico: chamada com local, "chamar de novo", consulta com UrgencySecrecy::CID e alta
      # para a UBS com orientação (a recusa do destino ausente antes).
      sign_in_as(doctor)
      req.(:post, "/attendance/attendances/#{ids[:a_attendance]}/call", { health_unit_id: upa.id, call_location_id: room.id })
      req.(:post, "/attendance/attendances/#{ids[:a_attendance]}/recall", { call_location_id: room.id })
      ids[:consultation_a] = req.(:post, "/attendance/attendances/#{ids[:a_attendance]}/consultation", {})["id"]
      req.(:patch, "/attendance/consultations/#{ids[:consultation_a]}",
           draft_body.except("care_type").merge("evaluated_problems" => [ { "terminology" => "cid10", "code" => "I10", "action" => "add" } ]))
      req.(:post, "/attendance/consultations/#{ids[:consultation_a]}/finalize", {})
      refuse.(:missing_destination, "/urgency/encounters/#{ids[:a]}/outcome", { kind: "transferred" }, status: 422, sent: nil)
      req.(:post, "/urgency/encounters/#{ids[:a]}/outcome",
           { kind: "discharged_to_primary_care", return_guidance: { days: 3, reason: UrgencySecrecy::TEXTS[:return_reason] } })
      board.()

      # Recepção: identificação do provisório B com fusão no paciente; evasão do C.
      sign_in_as(reception)
      ids[:identified] = req.(:post, "/urgency/encounters/#{ids[:b]}/identify", { patient_id: patient.id })
      req.(:post, "/urgency/encounters/#{ids[:c]}/outcome", { kind: "left_without_care" })

      # Médico: o B, já do paciente, termina em óbito.
      sign_in_as(doctor)
      req.(:post, "/attendance/attendances/#{ids[:b_attendance]}/call", { health_unit_id: upa.id, call_location_id: room.id })
      ids[:consultation_b] = req.(:post, "/attendance/attendances/#{ids[:b_attendance]}/consultation", {})["id"]
      req.(:patch, "/attendance/consultations/#{ids[:consultation_b]}", draft_body.except("care_type"))
      req.(:post, "/attendance/consultations/#{ids[:consultation_b]}/finalize", {})
      req.(:post, "/urgency/encounters/#{ids[:b]}/outcome", { kind: "death" })

      # Recepção: chegada lançada por engano.
      sign_in_as(reception)
      ids[:e] = req.(:post, "/urgency/arrivals", { health_unit_id: upa.id, patient_id: patient.id })["encounter_id"]
      req.(:post, "/urgency/encounters/#{ids[:e]}/outcome", { kind: "registered_in_error", reason: UrgencySecrecy::TEXTS[:error_reason] })

      # TV revogada.
      stepped_up!(admin)
      req.(:post, "/waiting_room/displays/#{ids[:display]}/revoke", {})
    end

    { city: city, upa: upa, doctor: doctor, patient: patient.reload, phone: phone, ids: ids, token: @display_token,
      log: log, paths: paths, refusals: refusals, boards: boards, started_at: started_at }
  end

  describe "cenário" do
    # O cenário roda uma vez por arquivo (api#159); cada exemplo parte do
    # estado que ele deixou e abre a sua própria sessão de requisição.
    # O before(type: :request) do harness não roda aqui: o host vem à mão.
    seed_once do
      use_test_city_host!
      @scenario = secrecy_scenario!
    end
    let(:scenario) { @scenario }
    let(:ids) { scenario[:ids] }
    let(:patient) { scenario[:patient] }
    let(:identifiers) { [ patient.cpf, patient.cns, UrgencySecrecy::NAME ] }
    let(:clinical) { UrgencySecrecy::TEXTS.values }
    let(:secrets) { identifiers + clinical }
    def body = JSON.parse(response.body)

    it "percorreu o cenário inteiro (controle positivo)" do
      encounters = UrgencyEncounter.where(id: ids.values_at(:a, :b, :c, :e)).index_by(&:id)
      expect(encounters.values.map(&:state).uniq).to eq([ "closed" ])
      expect(UrgencyOutcome.where(urgency_encounter_id: ids.values_at(:a, :b, :c, :e)).pluck(:urgency_encounter_id, :kind))
        .to contain_exactly([ ids[:a], "discharged_to_primary_care" ], [ ids[:b], "death" ], [ ids[:c], "left_without_care" ],
                            [ ids[:e], "registered_in_error" ])
      expect(encounters[ids[:b]].attendance.patient_id).to eq(patient.id)
      expect(Patient.find(ids[:provisional_b]).merged_into_id).to eq(patient.id)
      expect(Patient.find(ids[:provisional_c])).to have_attributes(unidentified: true, merged_into_id: nil)
      expect(ids[:identified]).to include("merged" => true)
      expect(UrgencyClassification.where(urgency_encounter_id: ids[:a]).count).to eq(2)
      expect(Consultation.find(ids[:consultation_a])).to have_attributes(kind: "urgency").and be_finalized
      expect(PatientProblem.where(patient_id: patient.id).pluck(:code)).to include("I10")
      expect(AttendanceCall.where(attendance_id: ids[:a_attendance]).order(:called_at, :id).pluck(:kind)).to eq(%w[classification care care])
      expect(WaitingRoomDisplay.find(ids[:display])).to be_revoked
      expect(scenario[:refusals].map { |r| r[:label] })
        .to eq(%i[malformed_cpf short_description short_justification missing_destination])
    end

    # §12 e Q17: só chaves de id (`_id`), mais as contagens da fusão no
    # urgency.patient_identified; nenhum evento do cenário leva dado da pessoa.
    it "todo urgency.*, attendance.recalled e waiting_room.* leva só ids (e as contagens da fusão)" do
      events = DomainEvent.where(occurred_at: scenario[:started_at]..)
      module_events = events.select { |e| e.name.match?(/\A(urgency|waiting_room)\./) || e.name == "attendance.recalled" }
      expect(module_events.map(&:name).uniq)
        .to contain_exactly("urgency.arrived", "urgency.classified", "urgency.reclassified", "urgency.patient_identified",
                            "urgency.encounter_closed", "attendance.recalled", "waiting_room.display_paired",
                            "waiting_room.display_revoked")
      module_events.each do |event|
        counts = event.name == "urgency.patient_identified" ? %w[moved kept_duplicates] : []
        event.payload.each do |key, value|
          if counts.include?(key)
            expect(value).to be_an(Integer), "#{event.name}.#{key}"
          else
            expect(key).to match(/_id\z/), "#{event.name} publica #{key}"
            expect(value.to_s).to match(UrgencySecrecy::UUID), "#{event.name}.#{key}"
          end
        end
      end
      merged = module_events.find { |e| e.name == "urgency.patient_identified" }
      expect(merged.payload.keys).to contain_exactly("encounter_id", "patient_id", "merged_from_id", "moved", "kept_duplicates")

      payloads = DomainEvent.pluck(:name, :payload).to_json
      secrets.each { |secret| expect(payloads).not_to include(secret), "evento contém #{secret.inspect}" }
      expect(payloads).not_to match(UrgencySecrecy::CID)
      expect(payloads).not_to include(scenario[:token])
    end

    it "o log do cenário não tem CPF, CNS, nome, queixa, critério, UrgencySecrecy::CID, descrição, motivo nem o token da TV" do
      log = scenario[:log]
      expect(log).to include("/urgency/arrivals", "/waiting_room/board") # controle: o log capturou as requisições
      (secrets + [ scenario[:token] ]).each { |secret| expect(log).not_to include(secret), "log contém #{secret.inspect}" }
      expect(log).not_to match(UrgencySecrecy::CID)
      logged = log.scan(/"(complaint|unidentified|pain_scale|vital_signs|return_guidance|reason|justification)"\s*=>\s*([^,}]+)/)
      expect(logged.map(&:first).uniq)
        .to include("complaint", "unidentified", "pain_scale", "vital_signs", "return_guidance", "reason", "justification")
      expect(logged.map(&:last)).to all(include("[FILTERED]"))
    end

    it "toda recusa forçada traz só error, path e problems, sem o valor enviado" do
      expected = { malformed_cpf: %w[invalid_cpf cpf], short_description: %w[invalid_request unidentified.description],
                   short_justification: %w[justification_required justification], missing_destination: %w[destination_required destination] }
      scenario[:refusals].each do |refusal|
        json = refusal[:json]
        expect(json.keys - %w[error path problems]).to be_empty, "#{refusal[:label]}: #{json.keys}"
        expect(json.values_at("error", "path")).to eq(expected.fetch(refusal[:label]))
        Array(json["problems"]).each { |problem| expect(problem.keys - %w[path error]).to be_empty }
        expect(refusal[:raw]).not_to include(refusal[:sent]) if refusal[:sent]
        secrets.each { |secret| expect(refusal[:raw]).not_to include(secret), "#{refusal[:label]} contém #{secret.inspect}" }
      end
    end

    it "as URLs pedidas levam só ids" do
      expect(scenario[:paths].size).to be >= 30
      joined = scenario[:paths].join("\n")
      (secrets + [ scenario[:token], ids[:pairing_code] ]).each { |secret| expect(joined).not_to include(secret) }
      expect(joined).not_to match(UrgencySecrecy::CID)
    end

    # Task 12: o mesmo conjunto de chaves; nada da pessoa, nenhum id de
    # paciente, encontro ou atendimento, e a cor só nos tempos agregados.
    it "o painel da TV: só senha, local, tipo e hora; cor só em wait_times" do
      expect(scenario[:boards].size).to eq(2)
      scenario[:boards].each do |read|
        expect(read.keys).to contain_exactly("unit", "calls", "wait_times", "updated_at")
        expect(read["unit"]).to eq("name" => "UPA Boqueirão")
        expect(read["calls"]).not_to be_empty
        expect(read["calls"].map { |c| c.keys.sort }.uniq).to eq([ %w[called_at kind location ticket] ])
        expect(read["wait_times"].map { |w| w.keys.sort }.uniq).to eq([ %w[color median_minutes] ])
        outside = read.except("wait_times").to_json
        expect(outside).not_to match(UrgencySecrecy::COLOR_WORDS)
        text = read.to_json
        forbidden = secrets + [ patient.id, ids[:provisional_b], ids[:provisional_c], ids[:a], ids[:b], ids[:c],
                                ids[:a_attendance], ids[:b_attendance] ]
        forbidden.each { |secret| expect(text).not_to include(secret), "painel contém #{secret.inspect}" }
      end
      expect(scenario[:boards].last["calls"].map { |c| [ c["kind"], c["location"] ] })
        .to include([ "classification", "Sala de classificação" ], [ "care", "Consultório 1" ])
    end

    # Q13 e Q25: só o encontro fechado com atendimento; sem UrgencySecrecy::CID, cor, queixa,
    # critério, motivo, descrição, óbito, registro por engano nem provisório.
    it "o histórico do cidadão (wpda) traz a alta sem o motivo; óbito, engano e provisório ficam fora" do
      sign_in_citizen(scenario[:phone])
      citizen = Citizen.find_by!(phone: scenario[:phone])
      get "/citizen/history", params: { citizen_id: citizen.id }
      expect(response).to have_http_status(:ok)
      urgency = body["entries"].select { |e| e["kind"] == "urgency" }
      expect(urgency.map { |e| e["id"] }).to eq([ "urgency:#{ids[:a]}" ])
      expect(urgency.first).to include("title" => "Atendimento de urgência — UPA Boqueirão",
                                       "return_guidance" => "Procure a sua UBS em até 3 dias")
      ids.values_at(:b, :c, :e).each { |id| expect(response.body).not_to include(id) }
      expect(response.body).not_to match(UrgencySecrecy::CID)
      expect(response.body).not_to match(UrgencySecrecy::COLOR_WORDS)
      (clinical + [ "Óbito", "óbito", "death", "registered_in_error", "engano", "não identificado", "provisional" ])
        .each { |secret| expect(response.body).not_to include(secret), "histórico contém #{secret.inspect}" }
    end

    # Q27: a página do PEC mostra a urgência na forma profissional (cor e UrgencySecrecy::CID
    # permitidos); nunca queixa, critério, motivo do retorno, descrição, o
    # registro por engano nem o provisório.
    it "a página do PEC mostra cor e UrgencySecrecy::CID, nunca queixa, critério, motivo, descrição, engano nem provisório" do
      timeline_city!(record_mode: "integrated", clinical_record: false, documents: true, pec: true)
      get signed_pec_path(professional: UrgencySecrecy::DOCTOR_CPF, citizen: patient.cpf, cnes: "7654321")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Atendimento de urgência — UPA Boqueirão", "Laranja", "I10") # controle: forma profissional
      [ :complaint_a, :complaint_b, :criterion_a, :criterion_b, :return_reason, :description_b, :description_c, :error_reason ]
        .each { |key| expect(response.body).not_to include(UrgencySecrecy::TEXTS[key]), "PEC contém #{key}" }
      expect(response.body).not_to include("Registrado por engano")

      kinds = PecTimelinesController::KINDS
      shown = Timeline::Query.call(person: Timeline::Person.for_patient(patient), kinds: kinds, pec_view: true).entries
      urgency_ids = shown.select { |e| e.kind == "urgency" }.map(&:source_id)
      expect(urgency_ids).to include(ids[:a])
      expect(urgency_ids).not_to include(ids[:e], ids[:c])
      provisional = Patient.find(ids[:provisional_c])
      expect(Timeline::Query.call(person: Timeline::Person.for_patient(provisional), kinds: %w[urgency], pec_view: true).entries)
        .to be_empty
    end
  end
end

# §13 (nunca em URL): toda leitura do módulo recusa CPF, CNS e nome na query
# com o NOME da chave (P23), sem ecoar o valor.
RSpec.describe "Sigilo da urgência (32a) — query das leituras", type: :request do
  let!(:city) { urgency_city!(waiting_room: true) }
  let(:upa) { upa! }
  let(:reader) { staff_with("leitura-upa-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin", "citizen_verifier") }
  let(:token) { paired_display!(upa).last }
  let(:module_reads) do
    %w[/urgency/queue /urgency/counter_referrals /urgency/encounters/:id /urgency/dashboard /urgency/provisional_encounters
       /waiting_room/displays /waiting_room/board /attendance/call_locations] +
      # Módulo 32b: os leitos (Task 5), o mapa da observação (Task 6) e o aprazamento (Task 8).
      %w[/urgency/beds /urgency/observation /urgency/encounters/:id/medication_schedule]
  end

  it "GET /urgency/queue?cpf=… → 422 path cpf" do
    patient = urgency_patient!(1)
    sign_in_as(reader)
    get "/urgency/queue?health_unit_id=#{upa.id}&cpf=#{patient.cpf}"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)).to eq("error" => "invalid_request", "path" => "cpf",
                                            "problems" => [ { "path" => "cpf", "error" => "invalid_request" } ])
    expect(response.body).not_to include(patient.cpf)
  end

  it "toda rota GET de /urgency e /waiting_room (e os locais de chamada) recusa cpf, cns e name" do
    routes = Rails.application.routes.routes.select { |r| r.verb == "GET" }.map { |r| r.path.spec.to_s.delete_suffix("(.:format)") }
                  .select { |p| p.match?(%r{\A/(urgency|waiting_room)/}) || p.start_with?("/attendance/call_locations") }
    expect(routes).to match_array(module_reads)
    patient = urgency_patient!(2)
    values = { "cpf" => patient.cpf, "cns" => patient.cns, "name" => UrgencySecrecy::NAME }
    headers = { "X-Display-Token" => token }
    sign_in_as(reader)
    routes.each do |route|
      path = route.gsub(/:\w+/) { SecureRandom.uuid }
      values.each do |key, value|
        get "#{path}?#{key}=#{CGI.escape(value)}", headers: headers
        json = JSON.parse(response.body)
        expect([ response.status, json["error"], json["path"] ]).to eq([ 422, "invalid_request", key ]),
                                                                     "#{route}?#{key} → #{response.status} #{response.body}"
        expect(response.body).not_to include(value)
      end
    end
  end
end

# §12 (Todo Platform.audit novo entra em R18): o módulo não audita na
# plataforma. Platform.audit( é multilinha: procura-se o nome da chamada,
# que não quebra linha, em todo arquivo do módulo.
RSpec.describe "Sigilo da urgência (32a) — sem Platform.audit novo" do
  it "nenhum arquivo do módulo chama Platform.audit e R18 segue sem nome da urgência" do
    files = UrgencySecrecy::MODULE_GLOBS.flat_map { |glob| Dir[Rails.root.join(glob).to_s] }.uniq
    expect(files.size).to be >= 60
    offenders = files.select { |file| File.read(file).match?(/Platform\s*\.\s*audit\b/) }
    expect(offenders).to be_empty

    guard = File.read(Rails.root.join("spec/events/platform_event_payload_guard_spec.rb"))
    r18 = guard[/R18_PLATFORM_EVENT_NAMES = %w\[(.*?)\]\.freeze/m, 1].to_s.split
    expect(r18).to include("city.feature_changed")
    expect(r18.grep(/urgency|waiting_room|attendance/)).to be_empty
    expect(Platform::Features::KEYS).to include("urgency_care", "waiting_room_display")
  end
end

# Módulo 32b (ADR 0050; contrato §10 e §12 Q4–Q10; plano, Task 17): o sigilo da
# observação e da prescrição interna de ponta a ponta. Um cenário pelas rotas
# reais com os interruptores `urgency_care` e `urgency_stock_deduction` ligados:
# leitos, entrada e troca de leito, busca de medicamento, prescrição com
# instruções (com um controlado), aprazamento, checagem com baixa, checagem
# recusada com motivo, uma falta de estoque, a suspensão, a conciliação com
# nota, a evolução por outro médico da UPA (prontuário e adendo, Q8) e o
# desfecho; e as recusas forçadas (dose número, motivo curto, nota curta e lote
# vencido). Depois, as provas de ausência: eventos (só ids; a lista exata dos
# sete do 32b), log, recusas, URLs e trilha de leitura.
module UrgencyObservationSecrecy
  NAME = "Zenóbia Fulgêncio Albuquerque".freeze
  TEXTS = {
    instructions_a: "Instrução reservada XYZ após o café",
    instructions_b: "Cuidado reservado QWE com a veia",
    refused_reason: "Paciente recusou, queixa de enjoo reservada",
    suspension_reason: "Suspensa por alergia reservada GHI",
    reconciliation_note: "Reposição reservada JKL conferida",
    addendum: "Evolução reservada MNO: estável"
  }.freeze
  DOSES = { losartana: "37.25", diazepam: "2.75", amoxicilina: "875.5" }.freeze
  SEARCH_QUERY = "losart".freeze
  # Os sete eventos do 32b (contrato §10; Q10).
  EVENTS = %w[urgency.observation_started urgency.observation_ended urgency.prescription_issued urgency.prescription_suspended
              urgency.medication_checked urgency.stock_shortfall_recorded pharmacy.urgency_shortfall_reconciled].freeze
  EVENTS_32A = %w[urgency.arrived urgency.classified urgency.reclassified urgency.patient_identified urgency.encounter_closed
                  attendance.recalled waiting_room.display_paired waiting_room.display_revoked].freeze
  EVENT_FILTER = /\A(urgency|waiting_room)\.|\Aattendance\.recalled\z|\Apharmacy\.urgency_shortfall_reconciled\z/
  EXTRA_GLOBS = %w[
    app/services/pharmacy/alerts.rb app/services/pharmacy/ledger.rb app/services/pharmacy/statement.rb
    app/services/pharmacy/catalog.rb app/models/stock_movement.rb app/controllers/pharmacy/base_controller.rb
    app/commands/attendances/close.rb app/commands/consultations/add_addendum.rb
  ].freeze
  NEW_FILES = %w[
    app/commands/pharmacy/reconcile_urgency_shortfall.rb app/controllers/pharmacy/urgency_shortfalls_controller.rb
    app/commands/urgency/deduct_stock.rb app/commands/urgency/issue_prescription.rb app/commands/urgency/record_administration.rb
    app/commands/urgency/start_observation.rb app/controllers/urgency/medication_searches_controller.rb
    app/services/urgency/fefo.rb app/services/urgency/schedule.rb app/models/urgency_stock_shortfall.rb
    app/models/urgency_administration.rb app/models/urgency_prescription_item.rb
  ].freeze
end

RSpec.describe "Sigilo da urgência (32b)", type: :request do
  # Método, e não let: o cenário roda no seed_once (before(:context)).
  def secrecy = UrgencyObservationSecrecy

  # Cenário completo pelas rotas. A busca de medicamento vai num log próprio
  # em nível info (o de produção): o `Medications::Search` compartilhado do 19
  # interpola o termo no SQL, que só aparece em debug.
  def observation_scenario!
    texts = secrecy::TEXTS
    doses = secrecy::DOSES
    city = urgency_city!
    import_test_catalog!
    ciap2_release!; cid10_release!; sigtap_release!
    pharmacy_city!
    Platform::Features.set!(city: city, key: Urgency::StockGate::KEY, enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!

    losartana = catalog_item(268_856)
    diazepam = catalog_item(267_197)
    amoxicilina = catalog_item(271_089)
    upa = upa!
    location = unit_location!(upa)
    pharmacist = pharmacy_staff!(location, "pharmacist")
    doctor = observation_doctor!(upa)
    nurse = observation_nurse!(upa)
    next_shift = upa_doctor!(upa)
    admin = urgency_admin!
    patient = urgency_patient!(urgency_seq!).tap { |p| p.update!(full_name: secrecy::NAME) }
    encounter = in_care_encounter!(upa, patient: patient)
    urgency_consultation!(encounter, doctor: doctor)
    stock_unit = Pharmacy::DispensingUnit.for(losartana)
    fresh = StockLot.create!(catalog_item_id: losartana.id, catmat_code: losartana.catmat_code, lot_number: "SEC-OK", dispensing_unit: stock_unit,
                             expires_on: Time.zone.today + 90, created_by_user: pharmacy_admin!)
    stocked_lot!(location, item: losartana, quantity: "10", lot_number: fresh.lot_number, expires_on: fresh.expires_on)
    old = StockLot.create!(catalog_item_id: amoxicilina.id, catmat_code: amoxicilina.catmat_code, lot_number: "SEC-OLD",
                           dispensing_unit: Pharmacy::DispensingUnit.for(amoxicilina), expires_on: Time.zone.today - 1, created_by_user: pharmacy_admin!)
    stocked_lot!(location, item: amoxicilina, quantity: "10", lot_number: old.lot_number, expires_on: old.expires_on)

    paths = []
    refusals = []
    started_at = Time.current
    send_request = lambda do |verb, path, body|
      verb == :get ? get(path) : json_post(path, body)
      paths << request.fullpath
    end
    req = lambda do |verb, path, body = {}|
      send_request.(verb, path, body)
      raise "#{verb} #{path} → #{response.status} #{response.body}" unless response.successful?

      response.body.empty? ? {} : JSON.parse(response.body)
    end
    refuse = lambda do |label, path, body, status:, sent:|
      send_request.(:post, path, body)
      raise "#{label}: #{path} → #{response.status} #{response.body}" unless response.status == status

      refusals << { label: label, status: response.status, raw: response.body, json: JSON.parse(response.body), sent: sent }
    end
    viewed = -> { DomainEvent.where(name: "clinical_record.viewed").count }
    item = lambda do |catalog, key, **over|
      { catalog_item_id: catalog.id, dose: doses.fetch(key), dose_unit: "mg", route: "oral",
        frequency: { kind: "interval", interval_hours: 8 } }.merge(over)
    end

    ids = {}
    reads = {}
    search = nil
    log = capture_log do
      # Leitos (admin com step-up).
      stepped_up!(admin)
      bed_a = req.(:post, "/urgency/beds", { health_unit_id: upa.id, label: "OBS 01" })
      bed_b = req.(:post, "/urgency/beds", { health_unit_id: upa.id, label: "OBS 02" })
      ids[:bed_a] = (bed_a["bed"] || bed_a)["id"]
      ids[:bed_b] = (bed_b["bed"] || bed_b)["id"]

      # Médico: entrada no leito e troca (a troca encerra a estadia e abre outra).
      sign_in_as(doctor)
      req.(:post, "/urgency/encounters/#{encounter.id}/observation", { bed_id: ids[:bed_a] })
      req.(:post, "/urgency/encounters/#{encounter.id}/observation", { bed_id: ids[:bed_b] })

      # Prescrição: a recusa da dose número, e a v1 com instruções e um controlado.
      refuse.(:dose_number, "/urgency/encounters/#{encounter.id}/prescriptions", { items: [ item.(losartana, :losartana, dose: 37.55) ] },
              status: 422, sent: "37.55")
      issued = req.(:post, "/urgency/encounters/#{encounter.id}/prescriptions",
                    { items: [ item.(losartana, :losartana, instructions: texts[:instructions_a]),
                               item.(diazepam, :diazepam, instructions: texts[:instructions_b]),
                               item.(amoxicilina, :amoxicilina) ] })
      ids[:prescription] = issued.dig("prescription", "id")
      rows = issued.dig("prescription", "items")
      ids[:controlled] = rows[1]["controlled"]
      row_a, row_b, row_c = rows
      due = ->(row) { { prescription_item_id: row["id"], scheduled_at: row["first_dose_at"] } }

      # Aprazamento (trilha medication_schedule) e leitura do detalhe do encontro.
      req.(:get, "/urgency/encounters/#{encounter.id}/medication_schedule")
      req.(:get, "/urgency/encounters/#{encounter.id}")

      # Enfermagem: o mapa (sem trilha), a checagem com baixa pelo FEFO, a falta
      # (controlado sem saldo), a recusada com motivo e as recusas forçadas.
      sign_in_as(nurse)
      before = viewed.()
      req.(:get, "/urgency/observation?health_unit_id=#{upa.id}")
      reads[:map_views] = viewed.() - before
      req.(:post, "/urgency/administrations", due.(row_a).merge(status: "administered"))
      ids[:administered_lot] = json_body_of(response).dig("administration", "stock_lot", "id")
      checked_b = req.(:post, "/urgency/administrations", due.(row_b).merge(status: "administered"))
      ids[:shortfall] = checked_b["shortfall"]
      refuse.(:short_reason, "/urgency/administrations", due.(row_c).merge(status: "refused", reason: "curto"), status: 422, sent: "curto")
      refuse.(:expired_lot, "/urgency/administrations", due.(row_c).merge(status: "administered", stock_lot_id: old.id), status: 422, sent: old.lot_number)
      req.(:post, "/urgency/administrations", due.(row_c).merge(status: "refused", reason: texts[:refused_reason]))

      # Farmácia: a lista de faltas (sem trilha), a nota curta e a conciliação.
      sign_in_as(pharmacist)
      before = viewed.()
      listed = req.(:get, "/pharmacy/urgency_shortfalls?location_id=#{location.id}")
      reads[:shortfall_views] = viewed.() - before
      ids[:shortfall_row] = listed["items"].sole["shortfall_id"]
      refuse.(:short_note, "/pharmacy/urgency_shortfalls/#{ids[:shortfall_row]}/reconcile", { note: "curta" }, status: 422, sent: "curta")
      req.(:post, "/pharmacy/urgency_shortfalls/#{ids[:shortfall_row]}/reconcile", { note: texts[:reconciliation_note] })

      # Médico: motivo curto da suspensão, suspensão da v1 (ainda ativa, com o encontro aberto).
      sign_in_as(doctor)
      refuse.(:short_suspension, "/urgency/prescriptions/#{ids[:prescription]}/suspend", { reason: "curto" }, status: 422, sent: "curto")
      req.(:post, "/urgency/prescriptions/#{ids[:prescription]}/suspend", { reason: texts[:suspension_reason] })
      finalized_urgency!(encounter, doctor: doctor)

      # Q8: outro médico da UPA lê o prontuário em contexto e escreve o adendo, encontro aberto.
      sign_in_as(next_shift)
      req.(:get, "/attendance/attendances/#{encounter.attendance_id}/record")
      consultation = Consultation.find_by!(attendance_id: encounter.attendance_id)
      req.(:post, "/attendance/consultations/#{consultation.id}/addenda", { reason: "evolução do plantão", text: texts[:addendum] })

      # Desfecho.
      sign_in_as(doctor)
      req.(:post, "/urgency/encounters/#{encounter.id}/outcome", { kind: "discharged" })
    end

    # A busca de medicamento, em nível info (o de produção).
    info = StringIO.new
    sink = ActiveSupport::Logger.new(info).tap { |l| l.level = Logger::INFO }
    Rails.logger.broadcast_to(sink)
    begin
      sign_in_as(doctor)
      search = req.(:post, "/urgency/medication_search", { query: secrecy::SEARCH_QUERY })
    ensure
      Rails.logger.stop_broadcasting_to(sink)
    end

    { city: city, upa: upa, location: location, patient: patient.reload, encounter: encounter, ids: ids, reads: reads, search: search,
      active_ingredients: [ losartana, diazepam, amoxicilina ].map(&:active_ingredient), doctor: doctor, nurse: nurse, next_shift: next_shift,
      log: log, search_log: info.string, paths: paths, refusals: refusals, started_at: started_at }
  end

  def json_body_of(res) = JSON.parse(res.body)

  describe "cenário" do
    # O cenário roda uma vez por arquivo (api#159); cada exemplo parte do
    # estado que ele deixou e abre a sua própria sessão de requisição.
    # O before(type: :request) do harness não roda aqui: o host vem à mão.
    seed_once do
      use_test_city_host!
      @scenario = observation_scenario!
    end
    let(:scenario) { @scenario }
    let(:ids) { scenario[:ids] }
    let(:patient) { scenario[:patient] }
    let(:texts) { UrgencyObservationSecrecy::TEXTS.values }
    let(:doses) { UrgencyObservationSecrecy::DOSES.values }
    let(:secrets) { [ patient.cpf, patient.cns, UrgencyObservationSecrecy::NAME ] + scenario[:active_ingredients] + doses + texts }

    it "percorreu o cenário inteiro (controle positivo)" do
      encounter = scenario[:encounter].reload
      expect(encounter.state).to eq("closed")
      expect(UrgencyBedStay.where(urgency_encounter_id: encounter.id).count).to eq(2)
      expect(UrgencyBedStay.where(urgency_encounter_id: encounter.id).pluck(:urgency_bed_id)).to contain_exactly(ids[:bed_a], ids[:bed_b])
      prescription = UrgencyPrescription.find(ids[:prescription])
      expect(prescription.status).to eq("suspended")
      expect(ids[:controlled]).to be(true)
      expect(UrgencyAdministration.where(urgency_encounter_id: encounter.id).pluck(:status)).to contain_exactly("administered", "administered", "refused")
      expect(ids[:administered_lot]).to be_present
      expect(ids[:shortfall]).to eq("cause" => "insufficient_balance")
      expect(UrgencyStockShortfall.find(ids[:shortfall_row]).reconciled_at).to be_present
      expect(ConsultationAddendum.where(author_user_id: scenario[:next_shift].id).count).to eq(1)
      expect(scenario[:search]["items"]).not_to be_empty
      expect(scenario[:refusals].map { |r| r[:label] })
        .to eq(%i[dose_number short_reason expired_lot short_note short_suspension])
    end

    # Q10: os eventos do cenário no espaço do módulo são exatamente os do 32a
    # que a via real publica mais os sete do 32b; e todo payload só leva `_id` uuid.
    it "os eventos do 32b são exatamente os sete do contrato, todos só com ids (uuid)" do
      events = DomainEvent.where(occurred_at: scenario[:started_at]..)
      module_events = events.select { |e| e.name.match?(UrgencyObservationSecrecy::EVENT_FILTER) }
      names = module_events.map(&:name).uniq - UrgencyObservationSecrecy::EVENTS_32A
      expect(names).to contain_exactly(*UrgencyObservationSecrecy::EVENTS)
      expect(UrgencyObservationSecrecy::EVENTS.size).to eq(7)
      expect(module_events.count { |e| e.name == "urgency.observation_started" }).to eq(2)
      expect(module_events.count { |e| e.name == "urgency.observation_ended" }).to be >= 2 # a troca e o desfecho
      module_events.each do |event|
        expect(event.payload).not_to be_empty
        event.payload.each do |key, value|
          expect(key).to match(/_id\z/), "#{event.name} publica #{key}"
          expect(value.to_s).to match(UrgencySecrecy::UUID), "#{event.name}.#{key}"
        end
      end
      payloads = DomainEvent.pluck(:name, :payload).to_json
      secrets.each { |secret| expect(payloads).not_to include(secret), "evento contém #{secret.inspect}" }
      expect(payloads).not_to include(UrgencyObservationSecrecy::SEARCH_QUERY)
    end

    it "o log do cenário não tem nome, CPF, CNS, princípio ativo, dose, instruções, motivo nem nota" do
      log = scenario[:log]
      expect(log).to include("/urgency/administrations", "/urgency/encounters/#{scenario[:encounter].id}/prescriptions", "/pharmacy/urgency_shortfalls")
      secrets.each { |secret| expect(log).not_to include(secret), "log contém #{secret.inspect}" }
      logged = log.scan(/"(items|reason|note|text)"\s*=>\s*([^,}]+)/)
      expect(logged.map(&:first).uniq).to include("items", "reason", "note")
      expect(logged.map(&:last)).to all(include("[FILTERED]"))
    end

    # A busca de medicamento (Q4): o termo nunca na linha da requisição nem nos
    # Parameters. No nível debug o `Medications::Search` do 19, compartilhado,
    # interpola o termo no SQL (fora do escopo deste módulo); o log de produção
    # é info, e é nele que se prova.
    it "a busca de medicamento não deixa o termo no log de produção (info)" do
      log = scenario[:search_log]
      expect(log).to include("/urgency/medication_search") # controle
      expect(log.downcase).not_to include(UrgencyObservationSecrecy::SEARCH_QUERY)
      expect(log).to include("[FILTERED]")
      expect(scenario[:log].downcase).not_to include(UrgencyObservationSecrecy::SEARCH_QUERY) # fora do capture: a busca não está nele
    end

    it "toda recusa forçada traz só error, path e problems, sem o valor enviado" do
      expected = { dose_number: "dose", short_reason: "reason", expired_lot: "stock_lot_id", short_note: "note", short_suspension: "reason" }
      scenario[:refusals].each do |refusal|
        json = refusal[:json]
        expect(json.keys - %w[error path problems]).to be_empty, "#{refusal[:label]}: #{json.keys}"
        expect(json["path"].to_s).to end_with(expected.fetch(refusal[:label])), "#{refusal[:label]}: #{json}"
        Array(json["problems"]).each { |problem| expect(problem.keys - %w[path error]).to be_empty }
        expect(refusal[:raw]).not_to include(refusal[:sent])
        secrets.each { |secret| expect(refusal[:raw]).not_to include(secret), "#{refusal[:label]} contém #{secret.inspect}" }
      end
      expect(scenario[:refusals].find { |r| r[:label] == :expired_lot }[:json]["error"]).to eq("lot_invalid")
    end

    it "as URLs pedidas levam só ids" do
      expect(scenario[:paths].size).to be >= 20
      joined = scenario[:paths].join("\n")
      secrets.each { |secret| expect(joined).not_to include(secret) }
      expect(joined.downcase).not_to include(UrgencyObservationSecrecy::SEARCH_QUERY)
      expect(joined).to include("/urgency/medication_search", "/urgency/observation?health_unit_id=", "/medication_schedule")
    end

    it "o mapa da observação e a lista de faltas não gravam clinical_record.viewed; o prontuário do outro médico grava" do
      expect(scenario[:reads]).to eq(map_views: 0, shortfall_views: 0)
      views = DomainEvent.where(name: "clinical_record.viewed").select { |e| e.payload["user_id"] == scenario[:next_shift].id }
      expect(views.size).to eq(1)
      expect(views.sole.payload.keys).to contain_exactly("access", "user_id", "patient_id", "reason_code")
      expect(views.sole.payload.to_json).not_to include(UrgencyObservationSecrecy::NAME, patient.cpf)
    end
  end

  # §13 (nunca em URL): as leituras novas recusam CPF, CNS e nome na query com o
  # NOME da chave, sem ecoar o valor.
  describe "query das leituras" do
    let!(:city) { urgency_city! }
    let!(:catalog) { import_test_catalog! }
    let(:upa) { upa! }
    let(:reader) { staff_with("leitura-obs-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin", "citizen_verifier") }

    {
      "/urgency/observation" => %w[name cpf cns],
      "/urgency/encounters/:id/medication_schedule" => %w[cpf name cns]
    }.each do |route, keys|
      it "GET #{route} recusa #{keys.join(', ')} → 422 só com o nome da chave" do
        sign_in_as(reader)
        keys.each do |key|
          value = key == "name" ? "x" : "1"
          get "#{route.sub(':id', SecureRandom.uuid)}?#{key}=#{value}"
          expect([ response.status, JSON.parse(response.body)["error"], JSON.parse(response.body)["path"] ]).to eq([ 422, "invalid_request", key ])
          expect(response.body).not_to include("\"#{value}\"")
        end
      end
    end

    it "GET /pharmacy/urgency_shortfalls recusa cpf, cns e name → 422 só com o nome da chave" do
      pharmacy_city!
      location = unit_location!(upa)
      sign_in_as(pharmacy_staff!(location, "pharmacist"))
      %w[cpf cns name].each do |key|
        get "/pharmacy/urgency_shortfalls?location_id=#{location.id}&#{key}=1"
        json = JSON.parse(response.body)
        expect([ response.status, json["error"], json["path"] ]).to eq([ 422, "invalid_request", key ])
      end
    end
  end

  # §12 (R18 intacto): o 32b não audita na plataforma. Os arquivos novos entram
  # nas globs (o total sobe em relação ao 32a).
  describe "sem Platform.audit novo" do
    it "nenhum arquivo do 32b chama Platform.audit e R18 segue sem nome da urgência" do
      root = Rails.root
      files_32a = UrgencySecrecy::MODULE_GLOBS.flat_map { |glob| Dir[root.join(glob).to_s] }.uniq
      files = (files_32a + UrgencyObservationSecrecy::EXTRA_GLOBS.map { |path| root.join(path).to_s }).uniq
      expect(files.size).to be > files_32a.size
      expect(files.size).to be >= 100
      UrgencyObservationSecrecy::NEW_FILES.each { |path| expect(files).to include(root.join(path).to_s), "#{path} fora das globs" }
      offenders = files.select { |file| File.read(file).match?(/Platform\s*\.\s*audit\b/) }
      expect(offenders).to be_empty

      guard = File.read(root.join("spec/events/platform_event_payload_guard_spec.rb"))
      r18 = guard[/R18_PLATFORM_EVENT_NAMES = %w\[(.*?)\]\.freeze/m, 1].to_s.split
      expect(r18.grep(/urgency|waiting_room|attendance|pharmacy/)).to be_empty
      expect(Platform::Features::KEYS).to include("urgency_care", Urgency::StockGate::KEY)
    end
  end
end
