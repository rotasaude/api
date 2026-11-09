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
    let!(:scenario) { secrecy_scenario! }
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
       /waiting_room/displays /waiting_room/board /attendance/call_locations]
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
